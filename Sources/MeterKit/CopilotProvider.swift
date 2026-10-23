import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ProviderKit

public struct CopilotReading: Sendable, Equatable {
    public var windows: [UsageWindow]
    public var availability: ProviderAvailability
    public var notice: String?

    public init(windows: [UsageWindow], availability: ProviderAvailability, notice: String?) {
        self.windows = windows
        self.availability = availability
        self.notice = notice
    }
}

/// `GET https://api.github.com/copilot_internal/user`.
/// `percent_remaining` is remaining percent. `entitlement` of -1 and `unlimited: true` are not a used percent.
public enum CopilotQuota {
    public static let changedNotice = "Limited data. GitHub Copilot's unofficial quota response changed."
    public static let unlimitedNotice = "GitHub Copilot reports no finite quota."

    public static func parse(_ data: Data, now: Date) -> CopilotReading {
        guard let root = MeterJSON.object(data) else {
            return CopilotReading(windows: [], availability: .limited, notice: changedNotice)
        }
        let hasSnapshots = root["quota_snapshots"] != nil
        let hasLimited = root["limited_user_quotas"] != nil
        let hasMonthly = root["monthly_quotas"] != nil
        guard hasSnapshots || hasLimited || hasMonthly else {
            return CopilotReading(windows: [], availability: .limited, notice: changedNotice)
        }
        if hasSnapshots {
            guard let snapshots = MeterJSON.dictionary(root["quota_snapshots"]) else {
                return CopilotReading(windows: [], availability: .limited, notice: changedNotice)
            }
            let windows = paidWindows(snapshots, root: root, now: now)
            if !windows.isEmpty {
                return CopilotReading(windows: windows, availability: .ready, notice: nil)
            }
            if snapshots.isEmpty || snapshots.values.contains(where: isUnlimitedBucket) {
                return CopilotReading(windows: [], availability: .ready, notice: unlimitedNotice)
            }
            return CopilotReading(windows: [], availability: .limited, notice: changedNotice)
        }
        guard let limited = dictionaryIfPresent(root["limited_user_quotas"], present: hasLimited),
              let monthly = dictionaryIfPresent(root["monthly_quotas"], present: hasMonthly) else {
            return CopilotReading(windows: [], availability: .limited, notice: changedNotice)
        }
        let windows = freeWindows(limited: limited, monthly: monthly, root: root, now: now)
        if windows.isEmpty {
            return CopilotReading(windows: [], availability: .ready, notice: unlimitedNotice)
        }
        return CopilotReading(windows: windows, availability: .ready, notice: nil)
    }

    private static func paidWindows(
        _ snapshots: [String: Any],
        root: [String: Any],
        now: Date
    ) -> [UsageWindow] {
        let order = [
            ("premium_interactions", "premium", "Premium"),
            ("chat", "chat", "Chat"),
            ("completions", "completions", "Completions"),
        ]
        let fallback = resetDate(root)
        var windows: [UsageWindow] = []
        for (key, id, title) in order {
            guard let bucket = MeterJSON.dictionary(snapshots[key]) else { continue }
            if isUnlimitedBucket(bucket) { continue }
            let percent: Double?
            if let remaining = MeterJSON.double(bucket["percent_remaining"]), remaining.isFinite {
                percent = min(100, max(0, 100 - remaining))
            } else if let entitlement = MeterJSON.double(bucket["entitlement"]),
                      entitlement > 0,
                      let left = MeterJSON.double(bucket["remaining"]) {
                percent = MeterJSON.percent(used: entitlement - left, limit: entitlement)
            } else {
                percent = nil
            }
            guard let percent else { continue }
            windows.append(
                window(id: id, title: title, percent: percent, resetsAt: bucketReset(bucket, fallback: fallback), now: now)
            )
        }
        return windows
    }

    private static func freeWindows(
        limited: [String: Any],
        monthly: [String: Any],
        root: [String: Any],
        now: Date
    ) -> [UsageWindow] {
        let order = [("chat", "chat", "Chat"), ("completions", "completions", "Completions")]
        let resetsAt = resetDate(root)
        var windows: [UsageWindow] = []
        for (key, id, title) in order {
            guard let cap = MeterJSON.double(monthly[key]),
                  let remaining = MeterJSON.double(limited[key]),
                  remaining <= cap,
                  let percent = MeterJSON.percent(used: cap - remaining, limit: cap) else { continue }
            windows.append(window(id: id, title: title, percent: percent, resetsAt: resetsAt, now: now))
        }
        return windows
    }

    private static func isUnlimitedBucket(_ value: Any) -> Bool {
        guard let bucket = MeterJSON.dictionary(value) else { return false }
        if MeterJSON.bool(bucket["unlimited"]) == true { return true }
        if let entitlement = MeterJSON.double(bucket["entitlement"]), entitlement < 0 { return true }
        return false
    }

    private static func dictionaryIfPresent(_ value: Any?, present: Bool) -> [String: Any]? {
        if !present { return [:] }
        return MeterJSON.dictionary(value)
    }

    private static func resetDate(_ root: [String: Any]) -> Date? {
        if let utc = MeterJSON.isoDate(root["quota_reset_date_utc"]) { return utc }
        if let day = calendarDay(root["quota_reset_date"]) { return day }
        return calendarDay(root["limited_user_reset_date"])
    }

    private static func bucketReset(_ bucket: [String: Any], fallback: Date?) -> Date? {
        if let stamp = MeterJSON.double(bucket["quota_reset_at"]), stamp > 0 {
            return MeterJSON.unixDate(stamp)
        }
        return fallback
    }

    private static func calendarDay(_ value: Any?) -> Date? {
        guard let text = MeterJSON.string(value) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: text)
    }

    private static func window(
        id: String,
        title: String,
        percent: Double,
        resetsAt: Date?,
        now: Date
    ) -> UsageWindow {
        let soon = resetsAt.map { reset in
            let delta = reset.timeIntervalSince(now)
            return delta >= 0 && delta <= 6 * 60 * 60
        } ?? false
        return UsageWindow(
            id: id,
            title: title,
            usedPercent: percent,
            resetsAt: resetsAt,
            origin: .server,
            showsCountdown: soon
        )
    }
}

public enum CopilotTokenFiles {
    /// One level only. Prefers an object whose key contains `github.com` and an `oauth_token` string.
    /// Never reads `refresh_token`.
    public static func oauthToken(fromAppsJSON data: Data) -> String? {
        guard let root = MeterJSON.object(data) else { return nil }
        for key in root.keys.sorted() where key.contains("github.com") {
            if let object = MeterJSON.dictionary(root[key]),
               let token = MeterJSON.string(object["oauth_token"]) {
                return token
            }
        }
        return MeterJSON.string(root["oauth_token"])
    }

    /// `oauth_token` inside the top-level `github.com` block only.
    public static func oauthToken(fromHostsYAML text: String) -> String? {
        var inGitHub = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            if indent == 0, trimmed.hasSuffix(":") {
                let host = stripQuotes(String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces))
                inGitHub = host == "github.com"
                continue
            }
            guard inGitHub, indent > 0, let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            guard key == "oauth_token" else { continue }
            let value = stripQuotes(String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func stripQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let quoted = (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'"))
        return quoted ? String(value.dropFirst().dropLast()) : value
    }
}

public protocol CopilotTokenSource: Sendable {
    func oauthToken(home: URL, environment: [String: String]) -> String?
}

public struct CopilotConfigReader: CopilotTokenSource {
    public init() {}

    public func oauthToken(home: URL, environment: [String: String]) -> String? {
        let copilot = home.appendingPathComponent(".config/github-copilot")
        if let token = jsonToken(at: copilot.appendingPathComponent("apps.json")) { return token }
        if let token = jsonToken(at: copilot.appendingPathComponent("hosts.json")) { return token }
        let ghHosts = home.appendingPathComponent(".config/gh/hosts.yml")
        if let token = yamlToken(at: ghHosts) { return token }
        if let directory = environment["GH_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !directory.isEmpty {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue {
                let hosts = URL(fileURLWithPath: directory).appendingPathComponent("hosts.yml")
                if let token = yamlToken(at: hosts) { return token }
            }
        }
        return nil
    }

    private func jsonToken(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return CopilotTokenFiles.oauthToken(fromAppsJSON: data)
    }

    private func yamlToken(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return CopilotTokenFiles.oauthToken(fromHostsYAML: text)
    }
}

public struct CopilotProvider<HTTP: MeterHTTP, Token: CopilotTokenSource>: UsageProvider {
    public var id: String { ToolCatalog.copilot }
    public var displayName: String { "GitHub Copilot" }
    private let http: HTTP
    private let token: Token

    public init(http: HTTP, token: Token) {
        self.http = http
        self.token = token
    }

    public func refresh(_ request: ProviderRefreshRequest) async -> ProviderSnapshot {
        guard request.allowUnofficial, request.allowNetwork else {
            return ProviderSnapshot(providerID: id, checkedAt: request.now)
        }
        guard let session = token.oauthToken(home: request.home, environment: request.environment), !session.isEmpty else {
            return ProviderSnapshot(
                providerID: id,
                notice: "GitHub Copilot usage needs a token in the Copilot or gh config. Tidepool does not read the keychain and does not refresh tokens.",
                checkedAt: request.now
            )
        }
        switch await MeterCall.perform(Self.request(token: session), http: http) {
        case .ok(let body):
            let reading = CopilotQuota.parse(body, now: request.now)
            return ProviderSnapshot(
                providerID: id,
                windows: reading.windows,
                notice: scrubbed(reading.notice, token: session),
                checkedAt: request.now,
                availability: reading.availability
            )
        case .unauthorized:
            return ProviderSnapshot(
                providerID: id,
                notice: "Limited data. GitHub Copilot rejected the saved token. Tidepool does not refresh it.",
                checkedAt: request.now,
                availability: .limited
            )
        case .limited(let retry):
            return ProviderSnapshot(
                providerID: id,
                notice: "GitHub Copilot asked Tidepool to slow down.",
                checkedAt: request.now,
                retryAfter: retry
            )
        case .http(let status) where status == 404 || status == 410:
            return ProviderSnapshot(
                providerID: id,
                notice: "Limited data. GitHub Copilot's unofficial quota endpoint changed.",
                checkedAt: request.now,
                availability: .limited
            )
        case .http(let status):
            return ProviderSnapshot(
                providerID: id,
                notice: "GitHub Copilot returned HTTP \(status).",
                checkedAt: request.now
            )
        case .unreachable:
            return ProviderSnapshot(
                providerID: id,
                notice: "GitHub Copilot could not be reached.",
                checkedAt: request.now
            )
        }
    }

    /// Community clients of this unofficial route send these editor headers.
    /// That is the request shape, not a claim that Tidepool is VS Code.
    static func request(token: String) -> URLRequest {
        let url = URL(string: "https://api.github.com/copilot_internal/user")!
        var request = MeterRequest.bearer(url, method: "GET", token: token)
        request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func scrubbed(_ notice: String?, token: String) -> String? {
        guard let notice, !token.isEmpty else { return notice }
        return notice.replacingOccurrences(of: token, with: "")
    }
}

extension CopilotProvider where HTTP == MeterURLSession, Token == CopilotConfigReader {
    public init() {
        self.init(http: MeterURLSession(), token: CopilotConfigReader())
    }
}

public typealias LiveCopilotProvider = CopilotProvider<MeterURLSession, CopilotConfigReader>
