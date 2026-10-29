import Foundation
import Testing

@testable import ClaudeKit
@testable import GrokKit
@testable import MeterKit
@testable import ProviderKit

@Test func resetCountdownCountsHoursMinutesAndADueReset() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(ResetCopy.countdown(start, now: start) == "Reset due")
    #expect(ResetCopy.countdown(start.addingTimeInterval(-30), now: start) == "Reset due")
    #expect(ResetCopy.countdown(start.addingTimeInterval(59), now: start) == "Resets in 0m")
    #expect(ResetCopy.countdown(start.addingTimeInterval(60), now: start) == "Resets in 1m")
    #expect(ResetCopy.countdown(start.addingTimeInterval(3_599), now: start) == "Resets in 59m")
    #expect(ResetCopy.countdown(start.addingTimeInterval(3_600), now: start) == "Resets in 1h 0m")
    #expect(ResetCopy.countdown(start.addingTimeInterval(8_000), now: start) == "Resets in 2h 13m")
}

@Test func fiveHourAndWeeklyLinesIncludeTheResetClock() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    let resets = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 16, minute: 0))!
    let now = resets.addingTimeInterval(-(2 * 3_600 + 13 * 60))
    let fiveHour = ResetCopy.fiveHourLine(resets, now: now, calendar: calendar)
    #expect(fiveHour.hasPrefix("Resets in 2h 13m · "))
    #expect(fiveHour.contains("4:00") || fiveHour.contains("16:00"))
    let weekly = ResetCopy.weeklyLine(resets, calendar: calendar)
    #expect(weekly.hasPrefix("Resets "))
    #expect(weekly.contains("Thu"))
    #expect(weekly.contains("4:00") || weekly.contains("16:00"))
}

@Test func usageWindowThresholdsAreSeventyFiveAndNinety() {
    func window(_ percent: Double) -> UsageWindow {
        UsageWindow(
            id: "five_hour",
            title: "5-hour session",
            usedPercent: percent,
            resetsAt: nil,
            origin: .server,
            showsCountdown: true
        )
    }
    let under = window(74.9)
    #expect(!under.isNearLimit)
    #expect(!under.isAtLimit)
    let near = window(75)
    #expect(near.isNearLimit)
    #expect(!near.isAtLimit)
    let almost = window(89.9)
    #expect(almost.isNearLimit)
    #expect(!almost.isAtLimit)
    let at = window(90)
    #expect(at.isNearLimit)
    #expect(at.isAtLimit)
}

@Test func oauthBucketKeepsUtilizationWhenTheResetIsMissing() throws {
    let json = """
    {"five_hour":{"utilization":15},"seven_day":null,"seven_day_sonnet":{"utilization":4}}
    """.data(using: .utf8)!
    let usage = try OAuthUsage.parse(json)
    #expect(usage.fiveHour?.utilization == 15)
    #expect(usage.fiveHour?.resetsAt == nil)
    #expect(usage.sevenDay == nil)
    #expect(usage.sevenDaySonnet?.utilization == 4)
    #expect(usage.sevenDaySonnet?.resetsAt == nil)
}

@Test func blankEnvironmentValueDoesNotDetectAProvider() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let blank = ToolDetector.probe(
        home: home,
        applicationDirectories: [],
        path: "",
        environment: ["OPENROUTER_API_KEY": "   ", "DEEPSEEK_API_KEY": ""],
        fileManager: .default
    )
    let missed = ToolDetector.status(for: blank)
    #expect(missed.first { $0.id == ToolCatalog.openRouter }?.state == .notDetected)
    #expect(missed.first { $0.id == ToolCatalog.deepSeek }?.state == .notDetected)
    #expect(missed.first { $0.id == ToolCatalog.openRouter }?.evidence.isEmpty == true)

    let present = ToolDetector.probe(
        home: home,
        applicationDirectories: [],
        path: "",
        environment: ["OPENROUTER_API_KEY": "sk-or-secret"],
        fileManager: .default
    )
    let found = try #require(ToolDetector.status(for: present).first { $0.id == ToolCatalog.openRouter })
    #expect(found.state == .active)
    #expect(found.evidence == ["OPENROUTER_API_KEY"])
    #expect(!found.evidence.joined(separator: " ").contains("sk-or-secret"))
}

@Test func limitedDataFallbackKeepsNoInventedWindow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let apps = root.appendingPathComponent("Applications")
    try FileManager.default.createDirectory(at: apps.appendingPathComponent("Grok Bot.app"), withIntermediateDirectories: true)
    let input = ToolDetector.probe(home: root, applicationDirectories: [apps], path: "", environment: [:])
    let status = try #require(ToolDetector.status(for: input).first { $0.id == ToolCatalog.grokBot })
    #expect(status.state == .limitedData)
    #expect(status.evidence == ["Grok Bot.app"])
    let snapshot = await GrokBotProvider().refresh(
        ProviderRefreshRequest(now: Date(timeIntervalSince1970: 1_700_000_000), home: root, supportDirectory: root)
    )
    #expect(snapshot.availability == .limited)
    #expect(snapshot.windows.isEmpty)
    #expect(snapshot.notice?.isEmpty == false)
    #expect(snapshot.fiveHour == nil)

    let changed = CursorUsage.parse(Data(#"{"displayMessage":"You've used 10%"}"#.utf8))
    #expect(changed.availability == .limited)
    #expect(changed.windows.isEmpty)
    #expect(changed.notice?.hasPrefix("Limited data") == true)
}
