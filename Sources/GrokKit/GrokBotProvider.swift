import Foundation
import ProviderKit

public struct GrokBotProvider: UsageProvider {
    public var id: String { ToolCatalog.grokBot }
    public var displayName: String { "Grok Bot" }

    public init() {}

    public func refresh(_ request: ProviderRefreshRequest) async -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: id,
            notice: "Grok Bot doesn't share usage data yet.",
            checkedAt: request.now,
            availability: .limited
        )
    }
}
