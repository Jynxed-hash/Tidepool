import Foundation
import ProviderKit

public struct GeminiCredential: Sendable, Equatable {
    public var accessToken: String
    public var expiry: Date?
}

public enum GeminiCredentialProblem: Error, Sendable, Equatable {
    case unreadable
    case missingToken
    case expired
}

/// `~/.gemini/oauth_creds.json` as written by Gemini CLI. The refresh token is ignored.
public enum GeminiCredentials {
    public static func parse(_ data: Data, now: Date) -> Result<GeminiCredential, GeminiCredentialProblem> {
        guard let object = MeterJSON.object(data) else { return .failure(.unreadable) }
        guard let token = MeterJSON.string(object["access_token"]) else { return .failure(.missingToken) }
        let expiry = MeterJSON.unixDate(object["expiry_date"])
        if let expiry, expiry <= now { return .failure(.expired) }
        return .success(GeminiCredential(accessToken: token, expiry: expiry))
    }
}

public struct GeminiQuotaReading: Sendable, Equatable {
    public var windows: [UsageWindow]
    public var project: String?
}

public enum GeminiQuota {
    public static let loadURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    public static let quotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!

    public static func loadBody() -> Data {
        Data(#"{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}"#.utf8)
    }

    public static func project(from data: Data) -> String? {
        guard let object = MeterJSON.object(data) else { return nil }
        return MeterJSON.string(object["cloudaicompanionProject"])
    }

    public static func quotaBody(project: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["project": project])) ?? Data()
    }

    /// One window per `modelId`. When a model has several buckets, the lowest
    /// `remainingFraction` is the one Gemini CLI keeps. Used percent is
    /// `100 * (1 - remainingFraction)`.
    public static func windows(from data: Data, now: Date) -> (windows: [UsageWindow], truncated: Bool)? {
        guard let object = MeterJSON.object(data) else { return nil }
        guard let buckets = MeterJSON.array(object["buckets"]) else { return ([], false) }
        struct Candidate {
            var model: String
            var used: Double
            var resetsAt: Date?
        }
        var tightest: [String: Candidate] = [:]
        for entry in buckets {
            guard let bucket = MeterJSON.dictionary(entry),
                  let model = MeterJSON.string(bucket["modelId"]),
                  let remaining = MeterJSON.double(bucket["remainingFraction"]) else { continue }
            let used = min(100, max(0, (1 - remaining) * 100))
            let resetsAt = MeterJSON.isoDate(bucket["resetTime"])
            if let current = tightest[model], current.used >= used { continue }
            tightest[model] = Candidate(model: model, used: used, resetsAt: resetsAt)
        }
        let ranked = tightest.values.sorted { lhs, rhs in
            if lhs.used == rhs.used { return lhs.model < rhs.model }
            return lhs.used > rhs.used
        }
        var seen: [String: Int] = [:]
        let windows = ranked.prefix(6).map { candidate in
            let base = windowID(candidate.model)
            let count = (seen[base] ?? 0) + 1
            seen[base] = count
            let id = count == 1 ? base : "\(base)-\(count)"
            let soon = candidate.resetsAt.map { $0.timeIntervalSince(now) <= 6 * 3600 } ?? false
            return UsageWindow(
                id: id,
                title: candidate.model,
                usedPercent: candidate.used,
                resetsAt: candidate.resetsAt,
                origin: .server,
                showsCountdown: soon
            )
        }
        return (windows, ranked.count > 6)
    }

    private static func windowID(_ model: String) -> String {
        let mapped = model.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            return "-"
        }
        var text = String(mapped)
        while text.contains("--") {
            text = text.replacingOccurrences(of: "--", with: "-")
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return text.isEmpty ? "model" : text
    }
}

public struct GeminiProvider<HTTP: MeterHTTP>: UsageProvider {
    public var id: String { ToolCatalog.geminiCLI }
    public var displayName: String { "Gemini CLI" }
    private var http: HTTP

    public init(http: HTTP) {
        self.http = http
    }

    public func refresh(_ request: ProviderRefreshRequest) async -> ProviderSnapshot {
        guard request.allowNetwork else {
            return ProviderSnapshot(providerID: id, checkedAt: request.now)
        }
        let file = request.home.appendingPathComponent(".gemini/oauth_creds.json")
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            return ProviderSnapshot(
                providerID: id,
                notice: "Gemini CLI quota needs ~/.gemini/oauth_creds.json. Tidepool does not refresh the token.",
                checkedAt: request.now
            )
        }
        let credential: GeminiCredential
        switch GeminiCredentials.parse(data, now: request.now) {
        case .success(let value):
            credential = value
        case .failure(.expired):
            return ProviderSnapshot(
                providerID: id,
                notice: "Gemini CLI's saved access token is expired. Tidepool does not refresh it.",
                checkedAt: request.now
            )
        case .failure:
            return ProviderSnapshot(
                providerID: id,
                notice: "Gemini CLI quota needs an access_token in ~/.gemini/oauth_creds.json. Tidepool does not refresh it.",
                checkedAt: request.now
            )
        }

        let loaded = await MeterCall.perform(
            MeterRequest.bearer(GeminiQuota.loadURL, method: "POST", token: credential.accessToken, body: GeminiQuota.loadBody()),
            http: http
        )
        let project: String
        switch loaded {
        case .ok(let body):
            guard let found = GeminiQuota.project(from: body) else {
                return ProviderSnapshot(
                    providerID: id,
                    notice: "Gemini CLI did not return a project id, so Tidepool did not query quota.",
                    checkedAt: request.now
                )
            }
            project = found
        case .unauthorized:
            return rejected(request.now)
        case .limited(let retry):
            return slowed(request.now, retry: retry)
        case .http(let status):
            return ProviderSnapshot(providerID: id, notice: "Gemini CLI returned HTTP \(status).", checkedAt: request.now)
        case .unreachable:
            return ProviderSnapshot(providerID: id, notice: "Gemini CLI could not be reached.", checkedAt: request.now)
        }

        let quota = await MeterCall.perform(
            MeterRequest.bearer(
                GeminiQuota.quotaURL,
                method: "POST",
                token: credential.accessToken,
                body: GeminiQuota.quotaBody(project: project)
            ),
            http: http
        )
        switch quota {
        case .ok(let body):
            guard let parsed = GeminiQuota.windows(from: body, now: request.now) else {
                return ProviderSnapshot(
                    providerID: id,
                    notice: "Gemini CLI returned a response Tidepool could not read.",
                    checkedAt: request.now
                )
            }
            let notice: String?
            if parsed.truncated {
                notice = "Showing the 6 models closest to their limit."
            } else if parsed.windows.isEmpty {
                notice = "Gemini CLI returned no quota buckets."
            } else {
                notice = nil
            }
            return ProviderSnapshot(
                providerID: id,
                windows: parsed.windows,
                notice: notice,
                checkedAt: request.now
            )
        case .unauthorized:
            return rejected(request.now)
        case .limited(let retry):
            return slowed(request.now, retry: retry)
        case .http(let status):
            return ProviderSnapshot(providerID: id, notice: "Gemini CLI returned HTTP \(status).", checkedAt: request.now)
        case .unreachable:
            return ProviderSnapshot(providerID: id, notice: "Gemini CLI could not be reached.", checkedAt: request.now)
        }
    }

    private func rejected(_ now: Date) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: id,
            notice: "Gemini CLI rejected the saved access token. Tidepool does not refresh it.",
            checkedAt: now
        )
    }

    private func slowed(_ now: Date, retry: TimeInterval?) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: id,
            notice: "Gemini CLI asked Tidepool to slow down.",
            checkedAt: now,
            retryAfter: retry
        )
    }
}

extension GeminiProvider where HTTP == MeterURLSession {
    public init() {
        self.init(http: MeterURLSession())
    }
}

public typealias LiveGeminiProvider = GeminiProvider<MeterURLSession>
