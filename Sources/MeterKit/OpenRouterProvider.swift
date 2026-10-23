import Foundation
import ProviderKit

public struct OpenRouterReading: Sendable, Equatable {
    public var windows: [UsageWindow]
    public var today: UsageEstimate
    public var notice: String?

    public init(windows: [UsageWindow], today: UsageEstimate, notice: String?) {
        self.windows = windows
        self.today = today
        self.notice = notice
    }
}

/// `GET https://openrouter.ai/api/v1/key`. Fields are the ones in the current-key example.
public enum OpenRouterUsage {
    public static func parse(_ data: Data) -> OpenRouterReading? {
        guard let root = MeterJSON.object(data), let payload = MeterJSON.dictionary(root["data"]) else {
            return nil
        }
        var windows: [UsageWindow] = []
        if let limit = MeterJSON.double(payload["limit"]), limit > 0 {
            let used: Double?
            if let remaining = MeterJSON.double(payload["limit_remaining"]) {
                used = limit - remaining
            } else {
                used = MeterJSON.double(payload["usage"])
            }
            if let used, let percent = MeterJSON.percent(used: used, limit: limit) {
                let reset = MeterJSON.string(payload["limit_reset"])
                windows.append(
                    UsageWindow(
                        id: keyID(reset),
                        title: keyTitle(reset),
                        usedPercent: percent,
                        resetsAt: nil,
                        origin: .server,
                        showsCountdown: reset == "daily"
                    )
                )
            }
        }

        let budget = MeterJSON.dictionary(payload["effective_budget"])
        if let budget, let window = budgetWindow(budget, idPrefix: "budget") {
            windows.append(window)
        } else if let budgets = MeterJSON.array(payload["budgets"]) {
            for (index, entry) in budgets.enumerated() {
                guard let object = MeterJSON.dictionary(entry),
                      let window = budgetWindow(object, idPrefix: "budget-\(index + 1)") else { continue }
                windows.append(window)
            }
        }

        if let free = MeterJSON.dictionary(payload["free_model_daily_requests"]),
           let limit = MeterJSON.double(free["limit"]),
           let used = MeterJSON.double(free["used"]),
           let percent = MeterJSON.percent(used: used, limit: limit) {
            windows.append(
                UsageWindow(
                    id: "free-daily",
                    title: "Free models today",
                    usedPercent: percent,
                    resetsAt: nil,
                    origin: .server,
                    showsCountdown: true
                )
            )
        }

        var today = UsageEstimate(origin: .server)
        var hasDaily = false
        if let daily = MeterJSON.double(payload["usage_daily"]) {
            today.costUSD = Decimal(string: decimalString(daily), locale: Locale(identifier: "en_US_POSIX"))
            hasDaily = today.costUSD != nil
        }
        let notice = windows.isEmpty ? "This OpenRouter key has no spending limit." : nil
        if windows.isEmpty, !hasDaily {
            return OpenRouterReading(windows: [], today: .empty, notice: notice)
        }
        return OpenRouterReading(windows: windows, today: hasDaily ? today : .empty, notice: notice)
    }

    private static func budgetWindow(_ budget: [String: Any], idPrefix: String) -> UsageWindow? {
        guard let limit = MeterJSON.double(budget["limit_usd"]),
              let spent = MeterJSON.double(budget["spend_usd"]),
              let percent = MeterJSON.percent(used: spent, limit: limit) else { return nil }
        let interval = MeterJSON.string(budget["reset_interval"])
        return UsageWindow(
            id: "\(idPrefix)-\(interval ?? "open")",
            title: budgetTitle(interval),
            usedPercent: percent,
            resetsAt: MeterJSON.isoDate(budget["resets_at"]),
            origin: .server,
            showsCountdown: interval == "daily"
        )
    }

    private static func keyID(_ reset: String?) -> String {
        switch reset {
        case "daily": "key-daily"
        case "weekly": "key-weekly"
        case "monthly": "key-monthly"
        default: "key-limit"
        }
    }

    private static func keyTitle(_ reset: String?) -> String {
        switch reset {
        case "daily": "Daily key limit"
        case "weekly": "Weekly key limit"
        case "monthly": "Monthly key limit"
        default: "Key limit"
        }
    }

    private static func budgetTitle(_ interval: String?) -> String {
        switch interval {
        case "daily": "Daily budget"
        case "weekly": "Weekly budget"
        case "monthly": "Monthly budget"
        default: "Budget"
        }
    }

    private static func decimalString(_ value: Double) -> String {
        var text = String(value)
        if text.contains("e") || text.contains("E") {
            text = String(format: "%.6f", value)
        }
        return text
    }
}

public struct OpenRouterProvider<HTTP: MeterHTTP>: UsageProvider {
    public var id: String { ToolCatalog.openRouter }
    public var displayName: String { "OpenRouter" }
    private var http: HTTP

    public init(http: HTTP) {
        self.http = http
    }

    public func refresh(_ request: ProviderRefreshRequest) async -> ProviderSnapshot {
        guard request.allowNetwork else {
            return ProviderSnapshot(providerID: id, checkedAt: request.now)
        }
        guard let token = MeterJSON.environmentValue(request.environment, "OPENROUTER_API_KEY") else {
            return ProviderSnapshot(
                providerID: id,
                notice: "OpenRouter usage needs OPENROUTER_API_KEY.",
                checkedAt: request.now
            )
        }
        let url = URL(string: "https://openrouter.ai/api/v1/key")!
        switch await MeterCall.perform(MeterRequest.bearer(url, method: "GET", token: token), http: http) {
        case .ok(let body):
            guard let reading = OpenRouterUsage.parse(body) else {
                return ProviderSnapshot(
                    providerID: id,
                    notice: "OpenRouter returned a response Tidepool could not read.",
                    checkedAt: request.now
                )
            }
            return ProviderSnapshot(
                providerID: id,
                windows: reading.windows,
                today: reading.today,
                notice: reading.notice,
                checkedAt: request.now
            )
        case .unauthorized:
            return ProviderSnapshot(providerID: id, notice: "OpenRouter rejected the API key.", checkedAt: request.now)
        case .limited(let retry):
            return ProviderSnapshot(
                providerID: id,
                notice: "OpenRouter asked Tidepool to slow down.",
                checkedAt: request.now,
                retryAfter: retry
            )
        case .http(let status):
            return ProviderSnapshot(providerID: id, notice: "OpenRouter returned HTTP \(status).", checkedAt: request.now)
        case .unreachable:
            return ProviderSnapshot(providerID: id, notice: "OpenRouter could not be reached.", checkedAt: request.now)
        }
    }
}

extension OpenRouterProvider where HTTP == MeterURLSession {
    public init() {
        self.init(http: MeterURLSession())
    }
}

public typealias LiveOpenRouterProvider = OpenRouterProvider<MeterURLSession>
