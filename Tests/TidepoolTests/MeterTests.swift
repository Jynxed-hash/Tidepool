import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import MeterKit
@testable import ProviderKit

private struct ScriptedHTTP: MeterHTTP {
    var respond: @Sendable (URLRequest) async throws -> MeterResponse

    func send(_ request: URLRequest) async throws -> MeterResponse {
        try await respond(request)
    }
}

@Test func openRouterExampleUsesServerPercentsAndDailySpend() throws {
    let body = """
    {"data":{"label":"SECRET_PROMPT_TEXT","limit":100,"limit_remaining":74.5,"limit_reset":"monthly","usage":25.5,"usage_daily":25.5,"effective_budget":{"limit_usd":50,"spend_usd":32.5,"reset_interval":"weekly","resets_at":"2026-10-12T00:00:00.000Z"},"budgets":[{"limit_usd":50,"spend_usd":32.5,"reset_interval":"weekly"}],"free_model_daily_requests":{"limit":50,"remaining":38,"used":12}}}
    """.data(using: .utf8)!
    let reading = try #require(OpenRouterUsage.parse(body))
    #expect(reading.windows.map(\.id) == ["key-monthly", "budget-weekly", "free-daily"])
    #expect(reading.windows.map(\.title) == ["Monthly key limit", "Weekly budget", "Free models today"])
    #expect(reading.windows.map(\.usedPercent) == [25.5, 65, 24])
    #expect(reading.windows.allSatisfy { $0.origin == .server })
    #expect(reading.windows[1].resetsAt != nil)
    #expect(reading.windows[0].resetsAt == nil)
    #expect(TokenFormat.todayLine(reading.today) == "Today $25.50")
    #expect(reading.notice == nil)
    let rendered = reading.windows.map(\.title).joined(separator: " ")
    #expect(!rendered.contains("SECRET_PROMPT_TEXT"))
    #expect(reading.notice?.contains("SECRET_PROMPT_TEXT") != true)
}

@Test func openRouterNullLimitDoesNotInventAPercent() throws {
    let body = """
    {"data":{"limit":null,"limit_remaining":null,"usage_daily":1.25}}
    """.data(using: .utf8)!
    let reading = try #require(OpenRouterUsage.parse(body))
    #expect(reading.windows.isEmpty)
    #expect(reading.notice == "This OpenRouter key has no spending limit.")
    #expect(TokenFormat.todayLine(reading.today) == "Today $1.25")
}

@Test func openRouterProviderSendsTheKeyOnlyAsBearer() async throws {
    let http = ScriptedHTTP { request in
        #expect(request.url?.path == "/api/v1/key")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let body = Data(#"{"data":{"limit":10,"limit_remaining":4,"limit_reset":"daily"}}"#.utf8)
        return MeterResponse(status: 200, headers: [:], body: body)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let snapshot = await OpenRouterProvider(http: http).refresh(
        ProviderRefreshRequest(
            now: Date(timeIntervalSince1970: 1_792_672_800),
            home: root,
            supportDirectory: root,
            allowNetwork: true,
            environment: ["OPENROUTER_API_KEY": "test-key"]
        )
    )
    #expect(snapshot.windows.first?.id == "key-daily")
    #expect(snapshot.windows.first?.usedPercent == 60)
    #expect(snapshot.notice?.contains("test-key") != true)
    let quiet = await OpenRouterProvider(http: http).refresh(
        ProviderRefreshRequest(now: Date(), home: root, supportDirectory: root, allowNetwork: false, environment: ["OPENROUTER_API_KEY": "test-key"])
    )
    #expect(quiet.windows.isEmpty)
}

@Test func geminiKeepsTheTightestFractionAndDropsTheRefreshToken() async throws {
    let now = Date(timeIntervalSince1970: 1_792_672_800)
    let quota = """
    {"buckets":[{"modelId":"gemini-3-pro-preview","tokenType":"REQUESTS","remainingFraction":0.25,"resetTime":"2026-10-22T16:00:00Z","note":"SECRET_PROMPT_TEXT"},{"modelId":"gemini-3-pro-preview","tokenType":"INPUT_TOKENS","remainingFraction":0.9,"resetTime":"2026-10-23T00:00:00Z"},{"modelId":"gemini-flash","remainingFraction":1,"resetTime":"2026-10-23T00:00:00Z"}]}
    """.data(using: .utf8)!
    let parsed = try #require(GeminiQuota.windows(from: quota, now: now))
    #expect(parsed.truncated == false)
    #expect(parsed.windows.map(\.title) == ["gemini-3-pro-preview", "gemini-flash"])
    #expect(parsed.windows[0].usedPercent == 75)
    #expect(parsed.windows[0].origin == .server)
    #expect(parsed.windows[1].usedPercent == 0)
    #expect(!parsed.windows[0].title.contains("SECRET_PROMPT_TEXT"))

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let directory = root.appendingPathComponent(".gemini", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let creds = #"{"access_token":"access-1","refresh_token":"SECRET_REFRESH","expiry_date":1999999999999}"#
    try creds.write(to: directory.appendingPathComponent("oauth_creds.json"), atomically: true, encoding: .utf8)
    let http = ScriptedHTTP { request in
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(!body.contains("SECRET_REFRESH"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        if request.url?.absoluteString.contains("loadCodeAssist") == true {
            #expect(body.contains("GEMINI_CLI"))
            return MeterResponse(status: 200, headers: [:], body: Data(#"{"cloudaicompanionProject":"gen-lang-client"}"#.utf8))
        }
        #expect(body.contains("gen-lang-client"))
        return MeterResponse(status: 200, headers: [:], body: quota)
    }
    let snapshot = await GeminiProvider(http: http).refresh(
        ProviderRefreshRequest(now: now, home: root, supportDirectory: root, allowNetwork: true)
    )
    #expect(snapshot.windows.map(\.title) == ["gemini-3-pro-preview", "gemini-flash"])
    #expect(snapshot.notice == nil)
}

@Test func geminiExpiredTokenIsNotRefreshedOrSent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let directory = root.appendingPathComponent(".gemini", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try #"{"access_token":"access-1","expiry_date":1000}"#.write(
        to: directory.appendingPathComponent("oauth_creds.json"),
        atomically: true,
        encoding: .utf8
    )
    let http = ScriptedHTTP { _ in
        Issue.record("expired Gemini token must not be sent")
        return MeterResponse(status: 500, headers: [:], body: Data())
    }
    let snapshot = await GeminiProvider(http: http).refresh(
        ProviderRefreshRequest(
            now: Date(timeIntervalSince1970: 1_792_672_800),
            home: root,
            supportDirectory: root,
            allowNetwork: true
        )
    )
    #expect(snapshot.windows.isEmpty)
    #expect(snapshot.notice == "Gemini CLI's saved access token is expired. Tidepool does not refresh it.")
}

@Test func openCodeUsageReadsPercentAndReset() throws {
    let body = """
    {"usage":{"rolling":{"status":"ok","percent":5,"resetsAt":"2026-10-22T18:00:00.000Z","preview":"SECRET_PROMPT_TEXT"},"weekly":{"status":"ok","percent":46,"resetsAt":"2026-10-26T00:00:00Z"},"monthly":{"status":"ok"}}}
    """.data(using: .utf8)!
    let windows = try #require(OpenCodeUsage.windows(from: body))
    #expect(windows.map(\.id) == ["rolling", "weekly"])
    #expect(windows.map(\.title) == ["Rolling", "Weekly"])
    #expect(windows.map(\.usedPercent) == [5, 46])
    #expect(windows[0].origin == .server)
    #expect(windows[0].resetsAt != nil)
    #expect(!windows.map(\.title).joined().contains("SECRET_PROMPT_TEXT"))
}

@Test func zaiQuotaMapsKnownUnitsAndSkipsTheRest() throws {
    let body = """
    {"code":200,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"usage":800000000,"currentValue":127694464,"percentage":15,"nextResetTime":1770648402389,"note":"SECRET_PROMPT_TEXT"},{"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":4,"nextResetTime":1778262784969},{"type":"TIME_LIMIT","unit":5,"number":1,"percentage":45},{"type":"TOKENS_LIMIT","unit":9,"number":1,"percentage":99},{"type":"TOKENS_LIMIT","unit":3,"number":5}]}}
    """.data(using: .utf8)!
    let parsed = try #require(ZAIUsage.parse(body))
    #expect(parsed.failure == nil)
    #expect(parsed.windows.map(\.id) == ["five_hour", "weekly", "tools"])
    #expect(parsed.windows.map(\.title) == ["5-hour session", "Weekly", "Monthly tool calls"])
    #expect(parsed.windows.map(\.usedPercent) == [15, 4, 45])
    #expect(parsed.windows[0].origin == .server)
    #expect(parsed.windows[0].resetsAt != nil)
    #expect(!parsed.windows.map(\.title).joined().contains("SECRET_PROMPT_TEXT"))
}

@Test func zaiFailureDoesNotBecomeZeroPercent() throws {
    let body = Data(#"{"code":1113,"success":false,"msg":"no coding plan","data":null}"#.utf8)
    let parsed = try #require(ZAIUsage.parse(body))
    #expect(parsed.windows.isEmpty)
    #expect(parsed.failure == "no coding plan")
}

@Test func zaiChinaKeyStaysOnTheChinaHost() async {
    let http = ScriptedHTTP { request in
        #expect(request.url?.host == "open.bigmodel.cn")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer china-key")
        let body = Data(#"{"code":200,"success":true,"data":{"limits":[]}}"#.utf8)
        return MeterResponse(status: 200, headers: [:], body: body)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let snapshot = await ZAIProvider(http: http).refresh(
        ProviderRefreshRequest(
            now: Date(timeIntervalSince1970: 1_792_672_800),
            home: root,
            supportDirectory: root,
            allowNetwork: true,
            environment: ["ZAI_API_KEY": " ", "ZHIPUAI_API_KEY": "china-key"]
        )
    )
    #expect(snapshot.windows.isEmpty)
    #expect(snapshot.notice == "z.ai returned no coding-plan window Tidepool recognizes.")
    #expect(snapshot.notice?.contains("china-key") != true)
}

@Test func deepSeekBalanceIsNotAPercent() throws {
    let body = """
    {"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}],"note":"SECRET_PROMPT_TEXT"}
    """.data(using: .utf8)!
    let notice = try #require(DeepSeekBalance.notice(from: body))
    #expect(notice == "Sufficient for API calls. Balance 110.00 CNY (granted 10.00, topped up 100.00).")
    #expect(!notice.contains("SECRET_PROMPT_TEXT"))
    let empty = DeepSeekBalance.notice(from: Data(#"{"is_available":false}"#.utf8))
    #expect(empty == nil)
}

@Test func meterKeysAreDetectedWithoutStoringTheSecret() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let apps = root.appendingPathComponent("Applications")
    let home = root.appendingPathComponent("home")
    let bin = root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: apps.appendingPathComponent("ChatGPT.app"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: apps.appendingPathComponent("Windsurf.app"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    for name in ["copilot", "kiro-cli", "amp", "aider", "droid"] {
        let url = bin.appendingPathComponent(name)
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    let input = ToolDetector.probe(
        home: home,
        applicationDirectories: [apps],
        path: bin.path,
        environment: ["OPENROUTER_API_KEY": "sk-or-secret", "ZAI_API_KEY": " "],
        fileManager: .default
    )
    let status = ToolDetector.status(for: input)
    let openRouter = try #require(status.first { $0.id == ToolCatalog.openRouter })
    #expect(openRouter.state == .active)
    #expect(openRouter.evidence == ["OPENROUTER_API_KEY"])
    #expect(!openRouter.evidence.joined().contains("sk-or-secret"))
    #expect(status.first { $0.id == ToolCatalog.geminiCLI }?.state == .active)
    #expect(status.first { $0.id == ToolCatalog.zai }?.state == .notDetected)
    #expect(status.first { $0.id == ToolCatalog.copilot }?.state == .active)
    #expect(status.first { $0.id == ToolCatalog.copilot }?.unofficial == true)
    #expect(status.first { $0.id == ToolCatalog.windsurf }?.state == .comingSoon)
    #expect(status.first { $0.id == ToolCatalog.kiro }?.state == .comingSoon)
    #expect(status.first { $0.id == ToolCatalog.amp }?.state == .comingSoon)
    #expect(status.first { $0.id == ToolCatalog.aider }?.state == .comingSoon)
    #expect(status.first { $0.id == ToolCatalog.factory }?.state == .comingSoon)
    #expect(status.first { $0.id == ToolCatalog.chatGPT }?.state == .comingSoon)
    #expect(status.first { $0.id == ToolCatalog.deepSeek }?.state == .notDetected)
}
