import Foundation
import ProviderKit

public enum DeepSeekBalance {
    public static func notice(from data: Data) -> String? {
        guard let root = MeterJSON.object(data),
              let available = MeterJSON.bool(root["is_available"]),
              let infos = MeterJSON.array(root["balance_infos"]) else { return nil }
        let parts: [String] = infos.compactMap { entry in
            guard let info = MeterJSON.dictionary(entry),
                  let currency = MeterJSON.string(info["currency"]),
                  let total = MeterJSON.string(info["total_balance"]),
                  let granted = MeterJSON.string(info["granted_balance"]),
                  let topped = MeterJSON.string(info["topped_up_balance"]) else { return nil }
            return "\(total) \(currency) (granted \(granted), topped up \(topped))"
        }
        guard !parts.isEmpty else { return nil }
        let lead = available ? "Sufficient for API calls." : "Not sufficient for API calls."
        return "\(lead) Balance \(parts.joined(separator: "; "))."
    }
}

public struct DeepSeekProvider<HTTP: MeterHTTP>: UsageProvider {
    public var id: String { ToolCatalog.deepSeek }
    public var displayName: String { "DeepSeek" }
    private var http: HTTP

    public init(http: HTTP) {
        self.http = http
    }

    public func refresh(_ request: ProviderRefreshRequest) async -> ProviderSnapshot {
        guard request.allowNetwork else {
            return ProviderSnapshot(providerID: id, checkedAt: request.now)
        }
        guard let token = MeterJSON.environmentValue(request.environment, "DEEPSEEK_API_KEY") else {
            return ProviderSnapshot(
                providerID: id,
                notice: "DeepSeek balance needs DEEPSEEK_API_KEY.",
                checkedAt: request.now
            )
        }
        let url = URL(string: "https://api.deepseek.com/user/balance")!
        switch await MeterCall.perform(MeterRequest.bearer(url, method: "GET", token: token), http: http) {
        case .ok(let body):
            guard let notice = DeepSeekBalance.notice(from: body) else {
                return ProviderSnapshot(
                    providerID: id,
                    notice: "DeepSeek did not return a balance.",
                    checkedAt: request.now
                )
            }
            return ProviderSnapshot(providerID: id, notice: notice, checkedAt: request.now)
        case .unauthorized:
            return ProviderSnapshot(providerID: id, notice: "DeepSeek rejected the API key.", checkedAt: request.now)
        case .limited(let retry):
            return ProviderSnapshot(
                providerID: id,
                notice: "DeepSeek asked Tidepool to slow down.",
                checkedAt: request.now,
                retryAfter: retry
            )
        case .http(let status):
            return ProviderSnapshot(providerID: id, notice: "DeepSeek returned HTTP \(status).", checkedAt: request.now)
        case .unreachable:
            return ProviderSnapshot(providerID: id, notice: "DeepSeek could not be reached.", checkedAt: request.now)
        }
    }
}

extension DeepSeekProvider where HTTP == MeterURLSession {
    public init() {
        self.init(http: MeterURLSession())
    }
}

public typealias LiveDeepSeekProvider = DeepSeekProvider<MeterURLSession>
