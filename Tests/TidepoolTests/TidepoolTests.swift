import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import ClaudeKit
@testable import HookBridge
@testable import ProviderKit

struct MockHTTP: HTTPSending {
    var handler: @Sendable (URLRequest) -> HTTPResponse
    func send(_ request: URLRequest) async throws -> HTTPResponse { handler(request) }
}

struct StaticCredentials: CredentialReading {
    var token: String?
    var error: CredentialError?
    func accessToken(home: URL, now: Date) throws -> String {
        if let error { throw error }
        guard let token else { throw CredentialError.notFound }
        return token
    }
}

@Test func oauthRequestUsesTheUsageEndpoint() {
    let request = OAuthUsage.request(token: "secret-token")
    #expect(request.httpMethod == "GET")
    #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
    #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
}

@Test func oauthParserKeepsNullBucketsAndExtraUtilization() throws {
    let json = """
    {
      "five_hour": { "utilization": 42, "resets_at": "2026-10-22T19:53:00Z" },
      "seven_day": { "utilization": 61.2, "resets_at": "2026-10-26T16:00:00Z" },
      "seven_day_opus": null,
      "seven_day_sonnet": { "utilization": 18, "resets_at": "2026-10-26T16:00:00Z" },
      "extra_usage": { "is_enabled": true, "monthly_limit": 100, "used_credits": 12.5, "utilization": 12.5 }
    }
    """.data(using: .utf8)!
    let usage = try OAuthUsage.parse(json)
    #expect(usage.fiveHour?.utilization == 42)
    #expect(usage.fiveHour?.resetsAt == JSONDates.parseISO("2026-10-22T19:53:00Z"))
    #expect(usage.sevenDayOpus == nil)
    #expect(usage.sevenDaySonnet?.utilization == 18)
    #expect(usage.extra?.isEnabled == true)
    #expect(usage.extra?.utilization == 12.5)
}

@Test func oauthFetchMaps429() async {
    let http = MockHTTP { _ in
        HTTPResponse(status: 429, headers: ["Retry-After": "90"], body: Data())
    }
    await #expect(throws: UsageClientError.rateLimited(retryAfter: 90)) {
        try await OAuthUsage.fetch(token: "t", http: http)
    }
}

@Test func credentialsTreatLargeExpiresAtAsMilliseconds() throws {
    let future = Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
    let json = """
    {"claudeAiOauth":{"accessToken":"sk-ant-oat01-example","expiresAt":\(future)}}
    """.data(using: .utf8)!
    let token = try CredentialFile.accessToken(from: json, now: Date())
    #expect(token == "sk-ant-oat01-example")
}

@Test func credentialsRejectExpiredSeconds() {
    let json = """
    {"claudeAiOauth":{"accessToken":"sk-ant-oat01-example","expiresAt":100}}
    """.data(using: .utf8)!
    #expect(throws: CredentialError.expired) {
        try CredentialFile.accessToken(from: json, now: Date())
    }
}

@Test func statuslineReadsUnixResets() throws {
    let json = """
    {"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{"used_percentage":41.2,"resets_at":1738857600}}}
    """.data(using: .utf8)!
    let snapshot = try #require(StatuslineSnapshot.parse(json, capturedAt: Date(timeIntervalSince1970: 0)))
    #expect(snapshot.fiveHour?.usedPercentage == 23.5)
    #expect(snapshot.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_738_425_600))
    #expect(snapshot.sevenDay?.usedPercentage == 41.2)
}

@Test func transcriptDedupeAndIgnoresPromptText() {
    let secret = "SECRET_PROMPT_TEXT"
    let json = """
    {"type":"user","uuid":"u1","sessionId":"s1","timestamp":"2026-10-22T15:00:00Z","cwd":"/work/acme-web","gitBranch":"feat/checkout","message":{"role":"user","content":"\(secret)"}}
    {"type":"assistant","uuid":"a1","requestId":"req-1","sessionId":"s1","timestamp":"2026-10-22T15:00:02Z","message":{"id":"msg-1","role":"assistant","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
    {"type":"assistant","uuid":"a2","requestId":"req-1","sessionId":"s1","timestamp":"2026-10-22T15:00:03Z","message":{"id":"msg-1","role":"assistant","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":4,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"cache_creation":{"ephemeral_5m_input_tokens":2,"ephemeral_1h_input_tokens":0}}}}
    """.data(using: .utf8)!
    let parsed = TranscriptParser.parse(json)
    #expect(!String(describing: parsed).contains(secret))
    let deduped = TranscriptParser.dedupe(parsed)
    let assistant = deduped.filter { $0.messageID == "msg-1" }
    #expect(assistant.count == 1)
    #expect(assistant[0].usage?.output == 4)
    #expect(assistant[0].usage?.cache5m == 2)
    #expect(assistant[0].gitBranch == nil)
    let user = deduped.first { $0.role == "user" }
    #expect(user?.gitBranch == "feat/checkout")
    #expect(user?.cwd == "/work/acme-web")
}

@Test func blockMathSnapshot() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let calculator = BlockCalculator(calendar: calendar)
    func date(_ text: String) -> Date {
        JSONDates.parseISO(text)!
    }
    let blocks = calculator.blocks(from: [
        date("2026-10-22T10:15:00Z"),
        date("2026-10-22T14:50:00Z"),
        date("2026-10-22T15:10:00Z"),
        date("2026-10-22T21:30:00Z"),
    ])
    #expect(blocks.map(\.start) == [
        date("2026-10-22T10:00:00Z"),
        date("2026-10-22T15:00:00Z"),
        date("2026-10-22T21:00:00Z"),
    ])
    #expect(blocks[0].end == date("2026-10-22T15:00:00Z"))
    #expect(blocks[0].timestamps.count == 2)
}

@Test func listPriceForOpusAndUnknownModel() {
    let million = TokenUsage(input: 1_000_000)
    #expect(ListPrices.costUSD(usage: million, model: "claude-opus-5-5") == Decimal(string: "4"))
    let output = TokenUsage(output: 1_000_000)
    #expect(ListPrices.costUSD(usage: output, model: "claude-opus-5-5-20260101") == Decimal(string: "20"))
    let cache = TokenUsage(cacheRead: 1_000_000)
    #expect(ListPrices.costUSD(usage: cache, model: "claude-opus-5-5") == Decimal(string: "0.2"))
    let longHaiku = TokenUsage(input: 150_000)
    #expect(ListPrices.costUSD(usage: longHaiku, model: "claude-haiku-5-5") == Decimal(string: "0.075"))
    #expect(ListPrices.costUSD(usage: million, model: "claude-mystery") == nil)
}

@Test func hookIngestDropsThePrompt() throws {
    let raw = """
    {"hook_event_name":"UserPromptSubmit","session_id":"abc","cwd":"/work/acme-web","prompt":"SECRET_PROMPT_TEXT","permission_mode":"default"}
    """.data(using: .utf8)!
    let event = try #require(HookIngest.event(from: raw, now: Date(timeIntervalSince1970: 10)))
    let encoded = try JSONEncoder().encode(event)
    let text = String(decoding: encoded, as: UTF8.self)
    #expect(!text.contains("SECRET_PROMPT_TEXT"))
    #expect(event.hook == "UserPromptSubmit")
    #expect(event.cwd == "/work/acme-web")
}

@Test func permissionRequestKeepsAShortCommand() throws {
    let raw = """
    {"hook_event_name":"PermissionRequest","session_id":"abc","cwd":"/work/acme-web","tool_name":"Bash","tool_input":{"command":"npm test\\n--watch","description":"Run tests"}}
    """.data(using: .utf8)!
    let event = try #require(HookIngest.event(from: raw, now: Date(timeIntervalSince1970: 10)))
    #expect(event.toolName == "Bash")
    #expect(event.toolDetail == "npm test")
}

@Test func sessionFoldFromHooks() {
    let start = Date(timeIntervalSince1970: 1_000)
    let events = [
        HookEvent(timestamp: start, hook: "UserPromptSubmit", sessionID: "s", cwd: "/repo/acme-web"),
        HookEvent(timestamp: start.addingTimeInterval(5), hook: "PermissionRequest", sessionID: "s", cwd: "/repo/acme-web", toolName: "Bash", toolDetail: "npm test"),
        HookEvent(timestamp: start.addingTimeInterval(9), hook: "Stop", sessionID: "other", cwd: "/repo/docs"),
    ]
    let sessions = SessionFolder.fold(events: events, now: start.addingTimeInterval(20))
    let acme = sessions.first { $0.id == "s" }
    #expect(acme?.activity == .needsYou)
    #expect(acme?.repo == "acme-web")
    #expect(acme?.waitingDetail == "npm test")
    #expect(acme?.origin == .hook)
    let docs = sessions.first { $0.id == "other" }
    #expect(docs?.activity == .idle)
}

@Test func transcriptHeuristicIsLabeledEstimate() {
    let now = Date(timeIntervalSince1970: 10_000)
    let hints = [
        TranscriptHint(sessionID: "s", cwd: "/repo/api", gitBranch: "main", lastRole: "assistant", lastTimestamp: now.addingTimeInterval(-90)),
    ]
    let sessions = SessionFolder.heuristic(hints: hints, now: now, excluding: [])
    #expect(sessions.count == 1)
    #expect(sessions[0].activity == .needsYou)
    #expect(sessions[0].origin == .estimate)
    #expect(sessions[0].branch == "main")
    let skipped = SessionFolder.heuristic(hints: hints, now: now, excluding: ["s"])
    #expect(skipped.isEmpty)
}

@Test func hookInstallerIsIdempotentAndRestores() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let settings = root.appendingPathComponent("settings.json")
    let backups = root.appendingPathComponent("backups")
    let original = """
    {"theme":"dark","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/local/bin/mine"}]}]},"statusLine":{"type":"command","command":"/usr/local/bin/status.sh"}}
    """.data(using: .utf8)!
    try original.write(to: settings)
    let command = "/Users/a/Library/Application Support/Tidepool/cmb-hook"
    let plan = HookInstallPlan(hookCommand: command, chainStatusline: true)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let first = try HookSettings.install(settingsURL: settings, backupDirectory: backups, plan: plan, now: now)
    #expect(first.changed)
    #expect(first.previousStatuslineCommand == "/usr/local/bin/status.sh")
    #expect(first.replacedStatusline)
    let second = try HookSettings.install(settingsURL: settings, backupDirectory: backups, plan: plan, now: now.addingTimeInterval(10))
    #expect(!second.changed)
    let backupsMade = try FileManager.default.contentsOfDirectory(atPath: backups.path)
    #expect(backupsMade.count == 1)
    let saved = try Data(contentsOf: backups.appendingPathComponent(backupsMade[0]))
    #expect(saved == original)
    let installed = try HookSettings.load(settings)
    let hooks = installed["hooks"] as? [String: Any]
    #expect(hooks?["Notification"] != nil)
    #expect(hooks?["Stop"] != nil)
    #expect(hooks?["PermissionRequest"] != nil)
    let pre = hooks?["PreToolUse"] as? [[String: Any]]
    let mine = ((pre?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)
    #expect(mine == "/usr/local/bin/mine")
    let removed = try HookSettings.uninstall(
        settingsURL: settings,
        backupDirectory: backups,
        restoreStatuslineCommand: "/usr/local/bin/status.sh",
        now: now.addingTimeInterval(20)
    )
    #expect(removed.changed)
    let restored = try HookSettings.load(settings)
    #expect(restored["theme"] as? String == "dark")
    let status = restored["statusLine"] as? [String: Any]
    #expect(status?["command"] as? String == "/usr/local/bin/status.sh")
    let afterHooks = restored["hooks"] as? [String: Any]
    #expect(afterHooks?["Notification"] == nil)
    #expect(afterHooks?["PreToolUse"] != nil)
    #expect(!HookSettings.isInstalled(at: settings))
}

@Test func hookInstallerRefusesInvalidJSON() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let settings = root.appendingPathComponent("settings.json")
    let original = Data("{".utf8)
    try original.write(to: settings)
    #expect(throws: HookSettingsError.invalidJSON) {
        try HookSettings.install(
            settingsURL: settings,
            backupDirectory: root.appendingPathComponent("backups"),
            plan: HookInstallPlan(hookCommand: "/Users/a/Library/Application Support/Tidepool/cmb-hook"),
            now: Date()
        )
    }
    #expect(try Data(contentsOf: settings) == original)
}

@Test func detectorFindsCursorAndDoesNotInventGrok() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let apps = root.appendingPathComponent("Applications")
    let home = root.appendingPathComponent("home")
    let bin = root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: apps.appendingPathComponent("Cursor.app"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: apps.appendingPathComponent("Wispr Flow.app"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let claude = bin.appendingPathComponent("claude")
    _ = FileManager.default.createFile(atPath: claude.path, contents: Data())
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
    let codexHome = root.appendingPathComponent("custom-codex")
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    let input = ToolDetector.probe(
        home: home,
        applicationDirectories: [apps],
        path: bin.path,
        environment: ["CODEX_HOME": codexHome.path],
        fileManager: .default
    )
    let status = ToolDetector.status(for: input)
    #expect(status.first { $0.id == ToolCatalog.cursor }?.state == .active)
    #expect(status.first { $0.id == ToolCatalog.cursor }?.unofficial == true)
    #expect(status.first { $0.id == ToolCatalog.wisprFlow }?.state == .comingSoon)
    #expect(status.first { $0.id == ToolCatalog.claudeCode }?.state == .active)
    #expect(status.first { $0.id == ToolCatalog.codex }?.state == .active)
    #expect(status.first { $0.id == ToolCatalog.grokBot }?.state == .notDetected)
    #expect(status.first { $0.id == ToolCatalog.grokBot }?.evidence.isEmpty == true)
}

@Test func providerUsesServerWindowsAndStatuslineFallback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let body = """
    {"five_hour":{"utilization":42,"resets_at":"2026-10-22T19:53:00Z"},"seven_day":{"utilization":61,"resets_at":"2026-10-26T16:00:00Z"},"seven_day_opus":{"utilization":18,"resets_at":"2026-10-26T16:00:00Z"}}
    """.data(using: .utf8)!
    let http = MockHTTP { request in
        #expect(request.url?.path == "/api/oauth/usage")
        return HTTPResponse(status: 200, headers: [:], body: body)
    }
    let provider = ClaudeCodeProvider(http: http, credentials: StaticCredentials(token: "token"), git: GitInspector { _, _ in nil })
    let now = Date(timeIntervalSince1970: 1_761_150_000)
    let live = await provider.refresh(ProviderRefreshRequest(now: now, home: root, supportDirectory: root, allowNetwork: true))
    #expect(live.windows.map(\.id) == ["five_hour", "seven_day", "seven_day_opus"])
    #expect(live.windows[0].origin == .server)
    #expect(live.fiveHour?.usedPercent == 42)

    let denied = ClaudeCodeProvider(
        http: MockHTTP { _ in HTTPResponse(status: 500, headers: [:], body: Data()) },
        credentials: StaticCredentials(error: .notFound),
        git: GitInspector { _, _ in nil }
    )
    let snapshot = StatuslineSnapshot(
        fiveHour: SavedRateWindow(usedPercentage: 9, resetsAt: now.addingTimeInterval(3600)),
        sevenDay: nil,
        capturedAt: now
    )
    try snapshot.write(to: TidepoolPaths.statuslineFile(support: root))
    let fallback = await denied.refresh(ProviderRefreshRequest(now: now, home: root, supportDirectory: root, allowNetwork: true))
    #expect(fallback.fiveHour?.origin == .statusline)
    #expect(fallback.fiveHour?.usedPercent == 9)
    #expect(fallback.notice?.contains("Sign in") == true)
}

@Test func todayFooterFormatsAnEstimate() {
    let estimate = UsageEstimate(tokens: 1_800_000, costUSD: Decimal(string: "14.20"), origin: .estimate)
    #expect(TokenFormat.todayLine(estimate) == "Today ≈ 1.8M tokens · ≈ $14.20")
    let countdown = ResetCopy.countdown(Date(timeIntervalSince1970: 8_000), now: Date(timeIntervalSince1970: 0))
    #expect(countdown == "Resets in 2h 13m")
}
