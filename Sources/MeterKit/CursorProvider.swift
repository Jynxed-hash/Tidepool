import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ProviderKit

public struct CursorReading: Sendable, Equatable {
    public var windows: [UsageWindow]
    public var availability: ProviderAvailability
    public var notice: String?

    public init(windows: [UsageWindow], availability: ProviderAvailability, notice: String?) {
        self.windows = windows
        self.availability = availability
        self.notice = notice
    }
}

/// `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`.
/// Amounts in `planUsage` and `spendLimitUsage` are cents. Percent fields are the API's own.
public enum CursorUsage {
    public static let changedNotice = "Limited data. Cursor's unofficial usage response changed."

    public static func parse(_ data: Data) -> CursorReading {
        guard let root = MeterJSON.object(data) else {
            return CursorReading(windows: [], availability: .limited, notice: changedNotice)
        }
        let cycleEnd = MeterJSON.unixDate(root["billingCycleEnd"])
        let plan = MeterJSON.dictionary(root["planUsage"])
        var windows: [UsageWindow] = []

        if let plan,
           let limit = MeterJSON.double(plan["limit"]),
           let included = MeterJSON.double(plan["includedSpend"]),
           let percent = MeterJSON.percent(used: included, limit: limit) {
            windows.append(window(id: "included", title: "Included", percent: percent, resetsAt: cycleEnd))
        }
        if let total = finitePercent(plan?["totalPercentUsed"]) {
            windows.append(window(id: "total", title: "Total", percent: total, resetsAt: cycleEnd))
        }
        if let auto = finitePercent(plan?["autoPercentUsed"]) {
            windows.append(window(id: "auto", title: "Auto", percent: auto, resetsAt: cycleEnd))
        }

        let primary = windows.contains { ["included", "total", "auto"].contains($0.id) }
        guard primary else {
            return CursorReading(windows: [], availability: .limited, notice: changedNotice)
        }

        if let spend = MeterJSON.dictionary(root["spendLimitUsage"]) {
            if let limit = MeterJSON.double(spend["individualLimit"]),
               let used = MeterJSON.double(spend["individualUsed"]),
               let percent = MeterJSON.percent(used: used, limit: limit) {
                windows.append(window(id: "on_demand", title: "On-demand", percent: percent, resetsAt: cycleEnd))
            }
            if let limit = MeterJSON.double(spend["pooledLimit"]),
               let used = MeterJSON.double(spend["pooledUsed"]),
               let percent = MeterJSON.percent(used: used, limit: limit) {
                windows.append(window(id: "team_pool", title: "Team pool", percent: percent, resetsAt: cycleEnd))
            }
        }

        return CursorReading(windows: windows, availability: .ready, notice: nil)
    }

    private static func finitePercent(_ value: Any?) -> Double? {
        guard let number = MeterJSON.double(value), number.isFinite else { return nil }
        return min(100, max(0, number))
    }

    private static func window(id: String, title: String, percent: Double, resetsAt: Date?) -> UsageWindow {
        UsageWindow(
            id: id,
            title: title,
            usedPercent: percent,
            resetsAt: resetsAt,
            origin: .server,
            showsCountdown: false
        )
    }
}

public protocol CursorSessionToken: Sendable {
    func accessToken(home: URL) -> String?
}

/// Read-only lookup of `cursorAuth/accessToken`. Never selects the refresh token and never writes the database.
public struct CursorStateDatabase: CursorSessionToken {
    public static let accessTokenSQL = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;"

    public init() {}

    public func accessToken(home: URL) -> String? {
        let database = home.appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        )
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: database.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else { return nil }
        return Self.query(uri: Self.readOnlyURI(for: database))
    }

    public static func readOnlyURI(for database: URL) -> String {
        let base = database.absoluteURL.absoluteString
        if base.contains("?") {
            return base + "&mode=ro"
        }
        return base + "?mode=ro"
    }

    private static func query(uri: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", uri, accessTokenSQL]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(whereSeparator: \.isNewline).first else { return nil }
        let token = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

public struct CursorProvider<HTTP: MeterHTTP, Token: CursorSessionToken>: UsageProvider {
    public var id: String { ToolCatalog.cursor }
    public var displayName: String { "Cursor" }
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
        guard let session = token.accessToken(home: request.home), !session.isEmpty else {
            return ProviderSnapshot(
                providerID: id,
                notice: "Cursor usage needs a signed-in session in Cursor. Tidepool does not refresh it.",
                checkedAt: request.now
            )
        }
        let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
        var call = MeterRequest.bearer(url, method: "POST", token: session, body: Data("{}".utf8))
        call.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        switch await MeterCall.perform(call, http: http) {
        case .ok(let body):
            let reading = CursorUsage.parse(body)
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
                notice: "Limited data. Cursor rejected the saved session. Tidepool does not refresh it.",
                checkedAt: request.now,
                availability: .limited
            )
        case .limited(let retry):
            return ProviderSnapshot(
                providerID: id,
                notice: "Cursor asked Tidepool to slow down.",
                checkedAt: request.now,
                retryAfter: retry
            )
        case .http(let status) where status == 404 || status == 410:
            return ProviderSnapshot(
                providerID: id,
                notice: "Limited data. Cursor's unofficial usage endpoint changed.",
                checkedAt: request.now,
                availability: .limited
            )
        case .http(let status):
            return ProviderSnapshot(
                providerID: id,
                notice: "Cursor returned HTTP \(status).",
                checkedAt: request.now
            )
        case .unreachable:
            return ProviderSnapshot(
                providerID: id,
                notice: "Cursor could not be reached.",
                checkedAt: request.now
            )
        }
    }

    private func scrubbed(_ notice: String?, token: String) -> String? {
        guard let notice, !token.isEmpty else { return notice }
        return notice.replacingOccurrences(of: token, with: "")
    }
}

extension CursorProvider where HTTP == MeterURLSession, Token == CursorStateDatabase {
    public init() {
        self.init(http: MeterURLSession(), token: CursorStateDatabase())
    }
}

public typealias LiveCursorProvider = CursorProvider<MeterURLSession, CursorStateDatabase>
