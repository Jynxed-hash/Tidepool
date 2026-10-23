import Foundation
import Testing

@testable import CodexKit
@testable import GrokKit
@testable import ProviderKit

@Test func codexSessionFileReadsServerWindowsAndDropsPromptText() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_792_672_800)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let day = root
        .appendingPathComponent(".codex/sessions/2026/10/22", isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    let file = day.appendingPathComponent("rollout-2026-10-22T12-00-00-thr_1.jsonl")
    let body = """
    {"timestamp":"2026-10-22T12:00:00Z","type":"session_meta","payload":{"id":"thr_1","cwd":"/repo/acme-web","timestamp":"2026-10-22T12:00:00Z"}}
    {"timestamp":"2026-10-22T12:01:00Z","type":"event_msg","payload":{"type":"user_message","message":"SECRET_PROMPT_TEXT"}}
    {"timestamp":"2026-10-22T12:02:00Z","type":"event_msg","payload":{"type":"task_started"}}
    {"timestamp":"2026-10-22T12:03:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":42,"window_minutes":300,"resets_at":1761140400},"secondary":{"used_percent":18,"window_minutes":10080,"resets_at":1761600000}}}}
    """
    try body.write(to: file, atomically: true, encoding: .utf8)
    let loaded = CodexRollout.load(codexHome: root.appendingPathComponent(".codex"), now: now, calendar: calendar)
    #expect(loaded.windows.map(\.id) == ["five_hour", "weekly"])
    #expect(loaded.windows[0].usedPercent == 42)
    #expect(loaded.windows[0].title == "5-hour session")
    #expect(loaded.windows[0].origin == .server)
    #expect(loaded.windows[1].title == "Weekly")
    #expect(loaded.sessions.count == 1)
    #expect(loaded.sessions[0].repo == "acme-web")
    #expect(loaded.sessions[0].activity == .working)
    #expect(loaded.sessions[0].origin == .estimate)
    #expect(loaded.sessions[0].waitingDetail == nil)
    #expect(loaded.sessions[0].branch == nil)
    let snapshot = await CodexProvider(live: StaticCodexLive(snapshot: nil)).refresh(
        ProviderRefreshRequest(now: now, home: root, supportDirectory: root, allowNetwork: true)
    )
    #expect(snapshot.notice == "From the latest Codex session file.")
    #expect(snapshot.fiveHour?.usedPercent == 42)
}

@Test func codexAppServerNamesWindowsFromDuration() {
    let line = """
    {"id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":25,"windowDurationMins":15,"resetsAt":1730947200},"secondary":{"usedPercent":61,"windowDurationMins":300,"resetsAt":1730950800}}}}}
    """
    let snapshot = CodexAppServer.parseMessages([line], now: Date(timeIntervalSince1970: 1_730_900_000))
    #expect(snapshot.windows?.map(\.title) == ["15 min", "5-hour session"])
    #expect(snapshot.windows?.map(\.id) == ["window-15", "five_hour"])
    #expect(snapshot.windows?[1].showsCountdown == true)
}

@Test func codexThreadListMarksApprovalAndDropsPreview() throws {
    let now = Date(timeIntervalSince1970: 1_792_672_800)
    let updated = Int(now.addingTimeInterval(-30).timeIntervalSince1970)
    let line = """
    {"id":3,"result":{"data":[{"id":"thr_a","name":"api","preview":"SECRET_PROMPT_TEXT","updatedAt":\(updated),"status":{"type":"active","activeFlags":["waitingOnApproval"]}},{"id":"thr_b","name":"docs","updatedAt":\(updated),"status":{"type":"idle"}}]}}
    """
    let snapshot = CodexAppServer.parseMessages([line], now: now)
    let sessions = try #require(snapshot.sessions)
    #expect(sessions[0].id == "thr_a")
    #expect(sessions[0].activity == .needsYou)
    #expect(sessions[0].waitingDetail == "Waiting on approval")
    #expect(sessions[0].origin == .server)
    #expect(sessions[1].activity == .idle)
    #expect(sessions[0].repo == "api")
    #expect(sessions[0].waitingDetail == "Waiting on approval")
}

@Test func codexUsageReadKeepsTodaysBucket() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_792_672_800)
    let line = """
    {"id":4,"result":{"summary":{"lifetimeTokens":99},"dailyUsageBuckets":[{"startDate":"2026-10-21","tokens":10},{"startDate":"2026-10-22","tokens":1800000}]}}
    """
    let snapshot = CodexAppServer.parseMessages([line], now: now, calendar: calendar)
    #expect(snapshot.todayTokens == 1_800_000)
    let today = UsageEstimate(tokens: snapshot.todayTokens ?? 0, origin: .server)
    #expect(TokenFormat.todayLine(today) == "Today 1.8M tokens")
}

@Test func codexClientDoesNotSendAccountOrResetMethods() {
    let outbound = CodexAppServer.outboundJSON().joined(separator: "\n").replacingOccurrences(of: "\\/", with: "/")
    #expect(outbound.contains("account/rateLimits/read"))
    #expect(outbound.contains("thread/list"))
    #expect(outbound.contains("account/usage/read"))
    #expect(!outbound.contains("account/read"))
    #expect(!outbound.contains("account/login"))
    #expect(!outbound.contains("rateLimitResetCredit"))
    #expect(!outbound.contains("/status"))
}

@Test func codexProviderPrefersLiveWindows() async throws {
    let now = Date(timeIntervalSince1970: 1_792_672_800)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let live = CodexLiveSnapshot(
        windows: [
            UsageWindow(id: "five_hour", title: "5-hour session", usedPercent: 7, resetsAt: now, origin: .server, showsCountdown: true),
        ],
        sessions: [
            TrackedSession(id: "thr", repo: "api", activity: .needsYou, waitingDetail: "Waiting on approval", updatedAt: now, origin: .server),
        ],
        todayTokens: 1200
    )
    let provider = CodexProvider(live: StaticCodexLive(snapshot: live))
    let snapshot = await provider.refresh(ProviderRefreshRequest(now: now, home: root, supportDirectory: root, allowNetwork: true))
    #expect(snapshot.fiveHour?.usedPercent == 7)
    #expect(snapshot.notice == nil)
    #expect(snapshot.sessions[0].activity == .needsYou)
    #expect(snapshot.today.origin == .server)
    #expect(snapshot.today.tokens == 1200)

    let offline = CodexProvider(live: StaticCodexLive(snapshot: nil))
    let quiet = await offline.refresh(ProviderRefreshRequest(now: now, home: root, supportDirectory: root, allowNetwork: false))
    #expect(quiet.windows.isEmpty)
    #expect(quiet.notice?.contains("signed-in") == true)
}

@Test func grokBotIsLimitedWhenTheAppIsInstalled() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let apps = root.appendingPathComponent("Applications")
    try? FileManager.default.createDirectory(at: apps.appendingPathComponent("Grok Bot.app"), withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: apps.appendingPathComponent("Cursor.app"), withIntermediateDirectories: true)
    let input = ToolDetector.probe(home: root, applicationDirectories: [apps], path: "", environment: [:])
    let status = ToolDetector.status(for: input)
    #expect(status.first { $0.id == ToolCatalog.grokBot }?.state == .limitedData)
    #expect(status.first { $0.id == ToolCatalog.cursor }?.state == .active)
    #expect(status.first { $0.id == ToolCatalog.cursor }?.unofficial == true)
    let snapshot = await GrokBotProvider().refresh(ProviderRefreshRequest(now: Date(), home: root, supportDirectory: root))
    #expect(snapshot.availability == .limited)
    #expect(snapshot.windows.isEmpty)
    #expect(snapshot.sessions.isEmpty)
    #expect(snapshot.notice?.contains("Usage & Billing") == true)
    #expect(snapshot.notice?.contains("grok.com/dashboard") == true)
}
