import Foundation
import ProviderKit

public struct GrokBotProvider: UsageProvider {
    public var id: String { ToolCatalog.grokBot }
    public var displayName: String { "Grok Bot" }

    public init() {}

    public func refresh(_ request: ProviderRefreshRequest) async -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: id,
            notice: """
            Grok Bot doesn't publish a usage figure this app can read. The weekly pool is in Grok Bot under Settings → Usage & Billing, and at grok.com/dashboard. Approval prompts stay in the Grok Bot conversation.
            """,
            checkedAt: request.now,
            availability: .limited
        )
    }
}
