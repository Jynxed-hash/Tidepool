import Foundation
import ProviderKit

public struct ZAIAccount: Sendable, Equatable {
    public var token: String
    public var url: URL
}

public enum ZAIUsage {
    public static let globalURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    public static let chinaURL = URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!

    /// `ZAI_API_KEY` stays on `api.z.ai`. `ZHIPUAI_API_KEY` stays on `open.bigmodel.cn`.
    /// When both are set, the global key is the one that is sent.
    public static func account(environment: [String: String]) -> ZAIAccount? {
        if let token = MeterJSON.environmentValue(environment, "ZAI_API_KEY") {
            return ZAIAccount(token: token, url: globalURL)
        }
        if let token = MeterJSON.environmentValue(environment, "ZHIPUAI_API_KEY") {
            return ZAIAccount(token: token, url: chinaURL)
        }
        return nil
    }

    public struct Parsed: Sendable, Equatable {
        public var windows: [UsageWindow]
        public var failure: String?
    }

    /// `percentage` is the used percent those clients display. Rows whose `unit`
    /// is not the 5-hour, weekly, or monthly tool code are skipped.
    public static func parse(_ data: Data) -> Parsed? {
        guard let root = MeterJSON.object(data) else { return nil }
        if MeterJSON.bool(root["success"]) == false {
            return Parsed(windows: [], failure: failureText(root["msg"]))
        }
        if let code = MeterJSON.int(root["code"]), code != 0, code != 200 {
            return Parsed(windows: [], failure: failureText(root["msg"]))
        }
        guard let payload = MeterJSON.dictionary(root["data"]) else {
            return Parsed(windows: [], failure: nil)
        }
        let limits = MeterJSON.array(payload["limits"]) ?? []
        var fiveHour: UsageWindow?
        var weekly: UsageWindow?
        var tools: UsageWindow?
        for entry in limits {
            guard let limit = MeterJSON.dictionary(entry),
                  let type = MeterJSON.string(limit["type"]),
                  let percent = MeterJSON.double(limit["percentage"]) else { continue }
            let unit = MeterJSON.int(limit["unit"])
            let number = MeterJSON.int(limit["number"])
            let resetsAt = MeterJSON.unixDate(limit["nextResetTime"])
            let used = min(100, max(0, percent))
            if (type == "TOKENS_LIMIT" || type == "CREDIT_LIMIT"), unit == 3, number == nil || number == 5 {
                fiveHour = UsageWindow(
                    id: "five_hour",
                    title: "5-hour session",
                    usedPercent: used,
                    resetsAt: resetsAt,
                    origin: .server,
                    showsCountdown: true
                )
            } else if (type == "TOKENS_LIMIT" || type == "CREDIT_LIMIT"), unit == 6, number == nil || number == 1 || number == 7 {
                weekly = UsageWindow(
                    id: "weekly",
                    title: "Weekly",
                    usedPercent: used,
                    resetsAt: resetsAt,
                    origin: .server,
                    showsCountdown: false
                )
            } else if type == "TIME_LIMIT", unit == 5, number == nil || number == 1 {
                tools = UsageWindow(
                    id: "tools",
                    title: "Monthly tool calls",
                    usedPercent: used,
                    resetsAt: resetsAt,
                    origin: .server,
                    showsCountdown: false
                )
            }
        }
        return Parsed(windows: [fiveHour, weekly, tools].compactMap { $0 }, failure: nil)
    }

    private static func failureText(_ value: Any?) -> String? {
        guard let text = MeterJSON.string(value), text.count <= 120, !text.contains("\n") else { return nil }
        return text
    }
}

public struct ZAIProvider<HTTP: MeterHTTP>: UsageProvider {
    public var id: String { ToolCatalog.zai }
    public var displayName: String { "z.ai" }
    private var http: HTTP

    public init(http: HTTP) {
        self.http = http
    }

    public func refresh(_ request: ProviderRefreshRequest) async -> ProviderSnapshot {
        guard request.allowNetwork else {
            return ProviderSnapshot(providerID: id, checkedAt: request.now)
        }
        guard let account = ZAIUsage.account(environment: request.environment) else {
            return ProviderSnapshot(
                providerID: id,
                notice: "z.ai usage needs ZAI_API_KEY or ZHIPUAI_API_KEY.",
                checkedAt: request.now
            )
        }
        switch await MeterCall.perform(MeterRequest.bearer(account.url, method: "GET", token: account.token), http: http) {
        case .ok(let body):
            guard let parsed = ZAIUsage.parse(body) else {
                return ProviderSnapshot(
                    providerID: id,
                    notice: "z.ai returned a response Tidepool could not read.",
                    checkedAt: request.now
                )
            }
            if let failure = parsed.failure {
                return ProviderSnapshot(
                    providerID: id,
                    notice: "z.ai did not return quota. \(failure)",
                    checkedAt: request.now
                )
            }
            if parsed.windows.isEmpty {
                let missing = MeterJSON.dictionary(MeterJSON.object(body)?["data"]) == nil
                let notice = missing
                    ? "z.ai did not return quota."
                    : "z.ai returned no coding-plan window Tidepool recognizes."
                return ProviderSnapshot(providerID: id, notice: notice, checkedAt: request.now)
            }
            return ProviderSnapshot(providerID: id, windows: parsed.windows, checkedAt: request.now)
        case .unauthorized:
            return ProviderSnapshot(providerID: id, notice: "z.ai rejected the API key.", checkedAt: request.now)
        case .limited(let retry):
            return ProviderSnapshot(
                providerID: id,
                notice: "z.ai asked Tidepool to slow down.",
                checkedAt: request.now,
                retryAfter: retry
            )
        case .http(let status):
            return ProviderSnapshot(providerID: id, notice: "z.ai returned HTTP \(status).", checkedAt: request.now)
        case .unreachable:
            return ProviderSnapshot(providerID: id, notice: "z.ai could not be reached.", checkedAt: request.now)
        }
    }
}

extension ZAIProvider where HTTP == MeterURLSession {
    public init() {
        self.init(http: MeterURLSession())
    }
}

public typealias LiveZAIProvider = ZAIProvider<MeterURLSession>
