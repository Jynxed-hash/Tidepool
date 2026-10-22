import Foundation
import HookBridge
import ProviderKit

public struct ClaudeCodeProvider<HTTP: HTTPSending, Credentials: CredentialReading>: UsageProvider {
    public var id: String { ToolCatalog.claudeCode }
    public var displayName: String { "Claude Code" }
    public var http: HTTP
    public var credentials: Credentials
    public var git: GitInspector

    public init(http: HTTP, credentials: Credentials, git: GitInspector = .live()) {
        self.http = http
        self.credentials = credentials
        self.git = git
    }

    public func refresh(_ request: ProviderRefreshRequest) async -> ProviderSnapshot {
        let projects = request.home.appendingPathComponent(".claude/projects")
        let entries = TranscriptFiles.loadRecent(
            projects: projects,
            notBefore: request.now.addingTimeInterval(-8 * 24 * 60 * 60)
        )
        let today = UsageRollup.today(entries: entries, now: request.now)
        let burn = UsageRollup.burnPerHour(entries: entries, now: request.now)
        let estimate = UsageEstimate(
            tokens: today.tokens,
            costUSD: today.cost,
            costIncomplete: today.incomplete,
            blockTokensPerHour: burn,
            origin: .estimate
        )

        let log = EventLog(fileURL: TidepoolPaths.eventsFile(support: request.supportDirectory))
        let events = (try? log.readAll()) ?? []
        var sessions = SessionFolder.fold(events: events, now: request.now)
        let hooked = Set(sessions.map(\.id))
        let hints = SessionFolder.hints(from: entries)
        sessions.append(contentsOf: SessionFolder.heuristic(hints: hints, now: request.now, excluding: hooked))
        sessions = enrich(sessions, hints: hints)
        sessions.sort(by: sortSessions)

        let usage = await windows(request: request)
        return ProviderSnapshot(
            providerID: id,
            windows: usage.windows,
            sessions: sessions,
            today: estimate,
            notice: usage.notice,
            checkedAt: request.now,
            retryAfter: usage.retryAfter
        )
    }

    private func windows(request: ProviderRefreshRequest) async -> (windows: [UsageWindow], notice: String?, retryAfter: TimeInterval?) {
        guard request.allowNetwork else {
            let fallback = fallback(request: request, notice: nil)
            return (fallback.windows, fallback.notice, nil)
        }
        do {
            let token = try credentials.accessToken(home: request.home, now: request.now)
            let usage = try await OAuthUsage.fetch(token: token, http: http)
            let built = windows(from: usage)
            if built.isEmpty {
                let fallback = fallback(request: request, notice: "Claude didn't return a usage window.")
                return (fallback.windows, fallback.notice, nil)
            }
            return (built, nil, nil)
        } catch let error as CredentialError {
            let notice: String
            switch error {
            case .expired:
                notice = "Claude Code's sign-in expired. Open Claude Code once so it can refresh."
            case .notFound, .malformed:
                notice = "Sign in with Claude Code, then open Tidepool again."
            }
            let fallback = fallback(request: request, notice: notice)
            return (fallback.windows, fallback.notice, nil)
        } catch let error as UsageClientError {
            let notice: String
            var retry: TimeInterval?
            switch error {
            case .unauthorized:
                notice = "Claude Code needs to refresh its sign-in. Open Claude Code once."
            case .rateLimited(let after):
                notice = "Usage check is waiting out a rate limit."
                retry = after
            default:
                notice = "Couldn't reach the usage service."
            }
            let fallback = fallback(request: request, notice: notice)
            return (fallback.windows, fallback.notice, retry)
        } catch {
            let fallback = fallback(request: request, notice: "Couldn't reach the usage service.")
            return (fallback.windows, fallback.notice, nil)
        }
    }

    private func fallback(request: ProviderRefreshRequest, notice: String?) -> (windows: [UsageWindow], notice: String?) {
        if let snapshot = StatuslineSnapshot.read(from: TidepoolPaths.statuslineFile(support: request.supportDirectory)),
           snapshot.fiveHour != nil || snapshot.sevenDay != nil {
            if let notice, !notice.isEmpty {
                return (windows(from: snapshot), "From the status line. \(notice)")
            }
            return (windows(from: snapshot), nil)
        }
        return ([], notice)
    }

    private func windows(from usage: OAuthUsage) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        if let bucket = usage.fiveHour {
            windows.append(UsageWindow(
                id: "five_hour",
                title: "5-hour session",
                usedPercent: bucket.utilization,
                resetsAt: bucket.resetsAt,
                origin: .server,
                showsCountdown: true
            ))
        }
        if let bucket = usage.sevenDay {
            windows.append(UsageWindow(
                id: "seven_day",
                title: "Weekly · all models",
                usedPercent: bucket.utilization,
                resetsAt: bucket.resetsAt,
                origin: .server,
                showsCountdown: false
            ))
        }
        if let bucket = usage.sevenDayOpus {
            windows.append(UsageWindow(
                id: "seven_day_opus",
                title: "Weekly · Opus",
                usedPercent: bucket.utilization,
                resetsAt: bucket.resetsAt,
                origin: .server,
                showsCountdown: false
            ))
        }
        if let bucket = usage.sevenDaySonnet {
            windows.append(UsageWindow(
                id: "seven_day_sonnet",
                title: "Weekly · Sonnet",
                usedPercent: bucket.utilization,
                resetsAt: bucket.resetsAt,
                origin: .server,
                showsCountdown: false
            ))
        }
        if let extra = usage.extra, extra.isEnabled, let utilization = extra.utilization {
            windows.append(UsageWindow(
                id: "extra_usage",
                title: "Extra usage",
                usedPercent: utilization,
                resetsAt: nil,
                origin: .server,
                showsCountdown: false
            ))
        }
        return windows
    }

    private func windows(from snapshot: StatuslineSnapshot) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        if let window = snapshot.fiveHour {
            windows.append(UsageWindow(
                id: "five_hour",
                title: "5-hour session",
                usedPercent: window.usedPercentage,
                resetsAt: window.resetsAt,
                origin: .statusline,
                showsCountdown: true
            ))
        }
        if let window = snapshot.sevenDay {
            windows.append(UsageWindow(
                id: "seven_day",
                title: "Weekly · all models",
                usedPercent: window.usedPercentage,
                resetsAt: window.resetsAt,
                origin: .statusline,
                showsCountdown: false
            ))
        }
        return windows
    }

    private func enrich(_ sessions: [TrackedSession], hints: [TranscriptHint]) -> [TrackedSession] {
        let byID = Dictionary(hints.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
        return sessions.map { session in
            var copy = session
            if copy.branch == nil {
                copy.branch = byID[copy.id]?.gitBranch
            }
            if copy.cwd == nil {
                copy.cwd = byID[copy.id]?.cwd
            }
            if let cwd = copy.cwd {
                let checkout = git.describe(cwd: URL(fileURLWithPath: cwd))
                if let branch = checkout.branch {
                    copy.branch = branch
                }
            }
            if copy.repo == "session", let name = SessionFolder.repoName(copy.cwd) {
                copy.repo = name
            }
            return copy
        }
    }

    private func sortSessions(_ lhs: TrackedSession, _ rhs: TrackedSession) -> Bool {
        func rank(_ activity: SessionActivity) -> Int {
            switch activity {
            case .needsYou: return 0
            case .working: return 1
            case .idle: return 2
            }
        }
        let left = rank(lhs.activity)
        let right = rank(rhs.activity)
        if left != right { return left < right }
        return lhs.updatedAt > rhs.updatedAt
    }
}

public typealias LiveClaudeProvider = ClaudeCodeProvider<URLSessionHTTP, ClaudeCredentialReader>
