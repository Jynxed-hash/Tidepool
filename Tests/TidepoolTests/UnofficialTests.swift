import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import MeterKit
@testable import ProviderKit

private final class CallProbe: @unchecked Sendable {
    var tokenReads = 0
    var httpSends = 0
}

private struct CountingCursorToken: CursorSessionToken {
    var probe: CallProbe
    var token: String?
    func accessToken(home: URL) -> String? {
        probe.tokenReads += 1
        return token
    }
}

private struct CountingCopilotToken: CopilotTokenSource {
    var probe: CallProbe
    var token: String?
    func oauthToken(home: URL, environment: [String: String]) -> String? {
        probe.tokenReads += 1
        return token
    }
}

private struct ScriptedHTTP: MeterHTTP {
    var respond: @Sendable (URLRequest) async throws -> MeterResponse

    func send(_ request: URLRequest) async throws -> MeterResponse {
        try await respond(request)
    }
}

@Test func cursorIncludedPercentIsSeparateFromTotalAndAuto() throws {
    let body = """
    {"billingCycleEnd":"1771077734000","planUsage":{"includedSpend":23222,"limit":40000,"totalPercentUsed":15.48,"autoPercentUsed":0,"apiPercentUsed":46.444},"spendLimitUsage":{"individualLimit":10000,"individualUsed":2500,"pooledLimit":50000,"pooledUsed":0,"limitType":"user"},"displayMessage":"You've used 58% of your included usage","note":"SECRET_PROMPT_TEXT"}
    """.data(using: .utf8)!
    let reading = CursorUsage.parse(body)
    #expect(reading.availability == .ready)
    #expect(reading.notice == nil)
    #expect(reading.windows.map(\.id) == ["included", "total", "auto", "on_demand", "team_pool"])
    #expect(reading.windows.map(\.title) == ["Included", "Total", "Auto", "On-demand", "Team pool"])
    #expect(abs(reading.windows[0].usedPercent - 58.055) < 0.001)
    #expect(reading.windows[1].usedPercent == 15.48)
    #expect(reading.windows[2].usedPercent == 0)
    #expect(reading.windows[3].usedPercent == 25)
    #expect(reading.windows[4].usedPercent == 0)
    #expect(reading.windows.allSatisfy { $0.origin == .server && $0.showsCountdown == false })
    #expect(reading.windows[0].resetsAt == Date(timeIntervalSince1970: 1_771_077_734))
    #expect(!reading.windows.contains { abs($0.usedPercent - 46.444) < 0.001 })
    let rendered = reading.windows.map(\.title).joined(separator: " ")
    #expect(!rendered.contains("SECRET_PROMPT_TEXT"))
    #expect(reading.notice?.contains("SECRET_PROMPT_TEXT") != true)
}

@Test func cursorUnrecognizedBodyIsLimitedData() {
    let reading = CursorUsage.parse(Data(#"{"enabled":true}"#.utf8))
    #expect(reading.windows.isEmpty)
    #expect(reading.availability == .limited)
    #expect(reading.notice?.hasPrefix("Limited data") == true)
}

@Test func cursorProviderDoesNotReadOrSendWhenUnofficialIsOff() async {
    let probe = CallProbe()
    let http = ScriptedHTTP { _ in
        probe.httpSends += 1
        return MeterResponse(status: 200, headers: [:], body: Data("{}".utf8))
    }
    let provider = CursorProvider(http: http, token: CountingCursorToken(probe: probe, token: "test-token"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let off = await provider.refresh(
        ProviderRefreshRequest(now: Date(), home: root, supportDirectory: root, allowNetwork: true, allowUnofficial: false)
    )
    #expect(off.windows.isEmpty)
    #expect(probe.tokenReads == 0)
    #expect(probe.httpSends == 0)
    let quiet = await provider.refresh(
        ProviderRefreshRequest(now: Date(), home: root, supportDirectory: root, allowNetwork: false, allowUnofficial: true)
    )
    #expect(quiet.windows.isEmpty)
    #expect(probe.tokenReads == 0)
    #expect(probe.httpSends == 0)
    let absent = CallProbe()
    let blocked = ScriptedHTTP { _ in
        absent.httpSends += 1
        return MeterResponse(status: 200, headers: [:], body: Data("{}".utf8))
    }
    let unsigned = await CursorProvider(http: blocked, token: CountingCursorToken(probe: absent, token: nil)).refresh(
        ProviderRefreshRequest(now: Date(), home: root, supportDirectory: root, allowNetwork: true, allowUnofficial: true)
    )
    #expect(unsigned.windows.isEmpty)
    #expect(unsigned.notice?.contains("signed-in") == true)
    #expect(unsigned.notice?.contains("test-token") != true)
    #expect(absent.tokenReads == 1)
    #expect(absent.httpSends == 0)
}

@Test func cursorProviderPostsTheSessionTokenOnce() async {
    let body = Data(#"{"planUsage":{"includedSpend":10,"limit":40,"totalPercentUsed":15.48,"autoPercentUsed":0}}"#.utf8)
    let http = ScriptedHTTP { request in
        #expect(request.url?.host == "api2.cursor.sh")
        #expect(request.url?.path.contains("GetCurrentPeriodUsage") == true)
        #expect(request.httpMethod == "POST")
        #expect(request.httpBody == Data("{}".utf8))
        #expect(request.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        return MeterResponse(status: 200, headers: [:], body: body)
    }
    let probe = CallProbe()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let snapshot = await CursorProvider(http: http, token: CountingCursorToken(probe: probe, token: "test-token")).refresh(
        ProviderRefreshRequest(now: Date(), home: root, supportDirectory: root)
    )
    #expect(snapshot.windows.first?.id == "included")
    #expect(snapshot.windows.first?.usedPercent == 25)
    #expect(snapshot.availability == .ready)
    #expect(snapshot.notice?.contains("test-token") != true)
    #expect(probe.tokenReads == 1)
    #expect(!CursorStateDatabase.accessTokenSQL.localizedCaseInsensitiveContains("refresh"))
    #expect(CursorStateDatabase.accessTokenSQL.contains("cursorAuth/accessToken"))
}

@Test func cursorStateDatabaseReadsTheAccessTokenAndDoesNotCreateSidecars() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let missing = CursorStateDatabase().accessToken(home: home)
    #expect(missing == nil)
    let database = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    #expect(!FileManager.default.fileExists(atPath: database.path))
    let uri = CursorStateDatabase.readOnlyURI(for: URL(fileURLWithPath: "/tmp/Application Support/state.vscdb"))
    #expect(uri.contains("mode=ro"))
    #expect(uri.contains("Application%20Support"))
    #expect(!uri.contains(" "))

    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else { return }
    try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
    let seed = Process()
    seed.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    seed.arguments = [
        database.path,
        "CREATE TABLE ItemTable (key TEXT, value TEXT); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'access-secret'); INSERT INTO ItemTable VALUES ('cursorAuth/refreshToken', 'refresh-secret');",
    ]
    seed.standardError = FileHandle.nullDevice
    try seed.run()
    seed.waitUntilExit()
    #expect(seed.terminationStatus == 0)
    let folder = database.deletingLastPathComponent()
    for suffix in ["-wal", "-shm"] {
        let side = database.path + suffix
        if FileManager.default.fileExists(atPath: side) {
            try FileManager.default.removeItem(atPath: side)
        }
    }
    let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    let token = CursorStateDatabase().accessToken(home: home)
    let after = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    #expect(token == "access-secret")
    #expect(token != "refresh-secret")
    #expect(before == after)
}

@Test func copilotPremiumUsedIsTheComplementOfPercentRemaining() throws {
    let now = Date(timeIntervalSince1970: 1_792_672_800)
    let body = """
    {"copilot_plan":"individual","quota_reset_date_utc":"2026-11-01T00:00:00Z","quota_snapshots":{"premium_interactions":{"percent_remaining":80,"entitlement":300,"remaining":240,"unlimited":false},"chat":{"unlimited":true,"entitlement":500,"percent_remaining":10},"completions":{"entitlement":-1,"percent_remaining":10}},"login":"SECRET_PROMPT_TEXT"}
    """.data(using: .utf8)!
    let reading = CopilotQuota.parse(body, now: now)
    #expect(reading.availability == .ready)
    #expect(reading.windows.map(\.id) == ["premium"])
    #expect(reading.windows.map(\.title) == ["Premium"])
    #expect(reading.windows[0].usedPercent == 20)
    #expect(reading.windows[0].origin == .server)
    let reset = ISO8601DateFormatter()
    reset.formatOptions = [.withInternetDateTime]
    #expect(reading.windows[0].resetsAt == reset.date(from: "2026-11-01T00:00:00Z"))
    #expect(!reading.windows[0].title.contains("SECRET_PROMPT_TEXT"))
    #expect(reading.notice == nil)
}

@Test func copilotEntitlementMathAndFreeTierStayServerFigures() throws {
    let now = Date(timeIntervalSince1970: 1_792_672_800)
    let paid = Data(#"{"quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":240}}}"#.utf8)
    let fromCounts = CopilotQuota.parse(paid, now: now)
    #expect(fromCounts.windows.first?.usedPercent == 20)
    #expect(fromCounts.windows.first?.origin == .server)

    let free = Data(#"{"limited_user_quotas":{"chat":40,"completions":1900},"monthly_quotas":{"chat":50,"completions":2000},"limited_user_reset_date":"2026-11-01"}"#.utf8)
    let reading = CopilotQuota.parse(free, now: now)
    #expect(reading.windows.map(\.title) == ["Chat", "Completions"])
    #expect(reading.windows.map(\.usedPercent) == [20, 5])
    #expect(reading.windows.allSatisfy { $0.origin == .server })
    let day = ISO8601DateFormatter()
    day.formatOptions = [.withFullDate]
    day.timeZone = TimeZone(secondsFromGMT: 0)
    #expect(reading.windows[0].resetsAt == day.date(from: "2026-11-01"))

    let oneSided = CopilotQuota.parse(Data(#"{"monthly_quotas":{"chat":50}}"#.utf8), now: now)
    #expect(oneSided.windows.isEmpty)
    #expect(oneSided.availability == .ready)
    #expect(oneSided.notice == CopilotQuota.unlimitedNotice)
}

@Test func copilotUnlimitedAndUnrecognizedBodies() {
    let now = Date(timeIntervalSince1970: 1_792_672_800)
    let unlimited = CopilotQuota.parse(
        Data(#"{"quota_snapshots":{"chat":{"unlimited":true},"completions":{"entitlement":-1}}}"#.utf8),
        now: now
    )
    #expect(unlimited.windows.isEmpty)
    #expect(unlimited.availability == .ready)
    #expect(unlimited.notice == "GitHub Copilot reports no finite quota.")

    let changed = CopilotQuota.parse(Data(#"{"login":"x"}"#.utf8), now: now)
    #expect(changed.windows.isEmpty)
    #expect(changed.availability == .limited)
    #expect(changed.notice?.hasPrefix("Limited data") == true)
}

@Test func copilotConfigIgnoresOtherHostsAndRefreshTokens() throws {
    let yaml = """
    github.com:
      user: octocat
      oauth_token: "gho_test"
    example.com:
      oauth_token: OTHER_SECRET
    """
    #expect(CopilotTokenFiles.oauthToken(fromHostsYAML: yaml) == "gho_test")
    #expect(CopilotTokenFiles.oauthToken(fromHostsYAML: "example.com:\n  oauth_token: OTHER_SECRET\n") == nil)

    let apps = Data(#"{"github.com:octocat":{"oauth_token":"ghu_test","refresh_token":"SECRET_REFRESH","user":"octocat"}}"#.utf8)
    #expect(CopilotTokenFiles.oauthToken(fromAppsJSON: apps) == "ghu_test")
    let refreshOnly = Data(#"{"github.com:octocat":{"refresh_token":"SECRET_REFRESH"}}"#.utf8)
    #expect(CopilotTokenFiles.oauthToken(fromAppsJSON: refreshOnly) == nil)

    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let gh = home.appendingPathComponent(".config/gh", isDirectory: true)
    try FileManager.default.createDirectory(at: gh, withIntermediateDirectories: true)
    try yaml.write(to: gh.appendingPathComponent("hosts.yml"), atomically: true, encoding: .utf8)
    let custom = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
    try "example.com:\n  oauth_token: OTHER_SECRET\n".write(to: custom.appendingPathComponent("hosts.yml"), atomically: true, encoding: .utf8)
    #expect(CopilotConfigReader().oauthToken(home: home, environment: ["GH_CONFIG_DIR": custom.path]) == "gho_test")

    let emptyHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
    #expect(CopilotConfigReader().oauthToken(home: emptyHome, environment: ["GH_CONFIG_DIR": custom.path]) == nil)
}

@Test func copilotProviderSendsTheConfigTokenAndNotTheRefreshToken() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let copilot = home.appendingPathComponent(".config/github-copilot", isDirectory: true)
    try FileManager.default.createDirectory(at: copilot, withIntermediateDirectories: true)
    let apps = #"{"github.com:octocat":{"oauth_token":"ghu_test","refresh_token":"SECRET_REFRESH"}}"#
    try apps.write(to: copilot.appendingPathComponent("apps.json"), atomically: true, encoding: .utf8)
    let body = Data(#"{"quota_reset_date_utc":"2026-11-01T00:00:00Z","quota_snapshots":{"premium_interactions":{"percent_remaining":80,"entitlement":300,"remaining":240}}}"#.utf8)
    let http = ScriptedHTTP { request in
        #expect(request.url?.host == "api.github.com")
        #expect(request.url?.path == "/copilot_internal/user")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_test")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("SECRET_REFRESH") != true)
        #expect(request.value(forHTTPHeaderField: "X-Github-Api-Version") == "2025-04-01")
        #expect(request.value(forHTTPHeaderField: "Editor-Version") == "vscode/1.96.2")
        #expect(request.value(forHTTPHeaderField: "Editor-Plugin-Version") == "copilot-chat/0.26.7")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "GitHubCopilotChat/0.26.7")
        return MeterResponse(status: 200, headers: [:], body: body)
    }
    let snapshot = await CopilotProvider(http: http, token: CopilotConfigReader()).refresh(
        ProviderRefreshRequest(now: Date(timeIntervalSince1970: 1_792_672_800), home: home, supportDirectory: home)
    )
    #expect(snapshot.windows.first?.usedPercent == 20)
    #expect(snapshot.notice?.contains("ghu_test") != true)
    #expect(snapshot.notice?.contains("SECRET_REFRESH") != true)
    let rendered = snapshot.windows.map(\.title).joined()
    #expect(!rendered.contains("SECRET_REFRESH"))
    #expect(!rendered.contains("ghu_test"))

    let probe = CallProbe()
    let blocked = ScriptedHTTP { _ in
        probe.httpSends += 1
        return MeterResponse(status: 500, headers: [:], body: Data())
    }
    let skipped = await CopilotProvider(http: blocked, token: CountingCopilotToken(probe: probe, token: "ghu_test")).refresh(
        ProviderRefreshRequest(now: Date(), home: home, supportDirectory: home, allowUnofficial: false)
    )
    #expect(skipped.windows.isEmpty)
    #expect(probe.tokenReads == 0)
    #expect(probe.httpSends == 0)
}

@Test func quietTickKeepsLimitedData() {
    let previous = ProviderSnapshot(
        providerID: ToolCatalog.cursor,
        notice: "Limited data. Cursor's unofficial usage response changed.",
        checkedAt: Date(timeIntervalSince1970: 1),
        availability: .limited
    )
    let fresh = ProviderSnapshot(providerID: ToolCatalog.cursor, checkedAt: Date(timeIntervalSince1970: 2))
    let merged = QuietTick.retaining(fresh, previous: previous)
    #expect(merged.availability == .limited)
    #expect(merged.notice?.hasPrefix("Limited data") == true)
    #expect(merged.windows.isEmpty)

    let kept = UsageWindow(
        id: "five_hour",
        title: "5-hour session",
        usedPercent: 10,
        resetsAt: nil,
        origin: .server,
        showsCountdown: true
    )
    let withWindows = ProviderSnapshot(
        providerID: ToolCatalog.claudeCode,
        windows: [kept],
        today: UsageEstimate(tokens: 4, origin: .server),
        notice: "kept",
        checkedAt: Date(),
        availability: .ready
    )
    let local = ProviderSnapshot(providerID: ToolCatalog.claudeCode, notice: "local", checkedAt: Date())
    let retained = QuietTick.retaining(local, previous: withWindows)
    #expect(retained.windows == [kept])
    #expect(retained.notice == "kept")
    #expect(retained.today.tokens == 4)
    #expect(retained.availability == .ready)

    let cursor = ProviderSnapshot(
        providerID: ToolCatalog.cursor,
        windows: [UsageWindow(id: "included", title: "Included", usedPercent: 58, resetsAt: nil, origin: .server, showsCountdown: false)],
        checkedAt: Date()
    )
    #expect(MenuMeter.window(in: withWindows)?.id == "five_hour")
    #expect(MenuMeter.window(in: cursor)?.id == "included")
}

@Test func editorCopilotConfigIsDetected() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/github-copilot"), withIntermediateDirectories: true)
    let input = ToolDetector.probe(home: home, applicationDirectories: [], path: "", environment: [:])
    let status = ToolDetector.status(for: input)
    let copilot = try #require(status.first { $0.id == ToolCatalog.copilot })
    #expect(copilot.state == .active)
    #expect(copilot.unofficial == true)
    #expect(copilot.evidence == [".config/github-copilot"])
}
