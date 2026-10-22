import Foundation
import ProviderKit

public struct CodexProvider<Live: CodexLiveReading>: UsageProvider {
    public var live: Live
    public var id: String { ToolCatalog.codex }
    public var displayName: String { "Codex" }

    public init(live: Live) {
        self.live = live
    }

    public func refresh(_ request: ProviderRefreshRequest) async -> ProviderSnapshot {
        let home = CodexRollout.codexHome(request: request)
        let files = CodexRollout.load(codexHome: home, now: request.now)
        var windows = files.windows
        var sessions = files.sessions
        var today = UsageEstimate()
        var notice: String? = windows.isEmpty ? nil : "From the latest Codex session file."

        if request.allowNetwork, let live = await live.read(environment: request.environment, now: request.now) {
            if let liveWindows = live.windows, !liveWindows.isEmpty {
                windows = liveWindows
                notice = nil
            }
            if let liveSessions = live.sessions, !liveSessions.isEmpty {
                sessions = liveSessions
            }
            if let tokens = live.todayTokens {
                today = UsageEstimate(tokens: tokens, origin: .server)
            }
        }

        if windows.isEmpty {
            notice = "Codex usage appears after a signed-in session."
        }

        return ProviderSnapshot(
            providerID: id,
            windows: windows,
            sessions: sessions,
            today: today,
            notice: notice,
            checkedAt: request.now
        )
    }
}

extension CodexProvider where Live == CodexProcessReader {
    public init() {
        self.init(live: CodexProcessReader())
    }
}

public typealias LiveCodexProvider = CodexProvider<CodexProcessReader>
