import Foundation
import HookBridge
import ProviderKit

public enum SessionFolder {
    public static func fold(events: [HookEvent], now: Date) -> [TrackedSession] {
        let ordered = events.sorted { $0.timestamp < $1.timestamp }
        var sessions: [String: TrackedSession] = [:]
        for event in ordered {
            switch event.hook {
            case "SessionEnd":
                sessions.removeValue(forKey: event.sessionID)
            case "SessionStart", "UserPromptSubmit":
                var session = sessions[event.sessionID] ?? blank(event)
                session.activity = .working
                session.waitingDetail = nil
                session.toolName = nil
                session.idleSince = nil
                session.updatedAt = event.timestamp
                session.cwd = event.cwd ?? session.cwd
                session.repo = repoName(event.cwd) ?? session.repo
                sessions[event.sessionID] = session
            case "PermissionRequest":
                var session = sessions[event.sessionID] ?? blank(event)
                session.activity = .needsYou
                session.toolName = event.toolName
                session.waitingDetail = event.toolDetail ?? event.message
                session.idleSince = nil
                session.updatedAt = event.timestamp
                session.cwd = event.cwd ?? session.cwd
                session.repo = repoName(event.cwd) ?? session.repo
                sessions[event.sessionID] = session
            case "Notification":
                guard let type = event.notificationType else { continue }
                var session = sessions[event.sessionID] ?? blank(event)
                session.cwd = event.cwd ?? session.cwd
                session.repo = repoName(event.cwd) ?? session.repo
                session.updatedAt = event.timestamp
                switch type {
                case "permission_prompt", "idle_prompt", "agent_needs_input":
                    session.activity = .needsYou
                    session.idleSince = nil
                    if session.waitingDetail == nil {
                        session.waitingDetail = event.message
                    }
                case "agent_completed":
                    session.activity = .idle
                    session.idleSince = event.timestamp
                    session.waitingDetail = nil
                default:
                    break
                }
                sessions[event.sessionID] = session
            case "Stop":
                var session = sessions[event.sessionID] ?? blank(event)
                session.cwd = event.cwd ?? session.cwd
                session.repo = repoName(event.cwd) ?? session.repo
                session.updatedAt = event.timestamp
                if (event.backgroundTaskCount ?? 0) > 0 {
                    session.activity = .working
                    session.idleSince = nil
                } else {
                    session.activity = .idle
                    session.idleSince = event.timestamp
                    session.waitingDetail = nil
                    session.toolName = nil
                }
                sessions[event.sessionID] = session
            default:
                break
            }
        }
        return Array(sessions.values)
    }

    /// Used only when a session has no hook events. The spec's heuristic is
    /// "the last transcript entry is assistant". Time bounds keep a finished
    /// session from staying on "Needs you" all day. The result is an estimate.
    public static func heuristic(hints: [TranscriptHint], now: Date, excluding: Set<String>) -> [TrackedSession] {
        hints.compactMap { hint in
            guard !excluding.contains(hint.sessionID) else { return nil }
            guard let timestamp = hint.lastTimestamp else { return nil }
            let age = now.timeIntervalSince(timestamp)
            guard age >= 0, age < 12 * 60 * 60 else { return nil }
            let activity: SessionActivity
            var idleSince: Date?
            switch hint.lastRole {
            case "user":
                activity = age < 15 * 60 ? .working : .idle
                if activity == .idle { idleSince = timestamp }
            case "assistant":
                if age < 30 {
                    activity = .working
                } else if age < 10 * 60 {
                    activity = .needsYou
                } else {
                    activity = .idle
                    idleSince = timestamp
                }
            default:
                activity = .idle
                idleSince = timestamp
            }
            return TrackedSession(
                id: hint.sessionID,
                repo: repoName(hint.cwd) ?? "session",
                branch: hint.gitBranch,
                cwd: hint.cwd,
                activity: activity,
                waitingDetail: activity == .needsYou ? "Waiting on you" : nil,
                idleSince: idleSince,
                updatedAt: timestamp,
                origin: .estimate
            )
        }
    }

    public static func hints(from entries: [TranscriptEntry]) -> [TranscriptHint] {
        var grouped: [String: TranscriptEntry] = [:]
        for entry in entries {
            guard let session = entry.sessionID else { continue }
            if let existing = grouped[session] {
                let existingTime = existing.timestamp ?? .distantPast
                let newTime = entry.timestamp ?? .distantPast
                if newTime >= existingTime {
                    grouped[session] = entry
                }
            } else {
                grouped[session] = entry
            }
        }
        return grouped.map { session, entry in
            TranscriptHint(
                sessionID: session,
                cwd: entry.cwd,
                gitBranch: entry.gitBranch,
                lastRole: entry.role,
                lastTimestamp: entry.timestamp
            )
        }
    }

    public static func repoName(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func blank(_ event: HookEvent) -> TrackedSession {
        TrackedSession(
            id: event.sessionID,
            repo: repoName(event.cwd) ?? "session",
            cwd: event.cwd,
            activity: .working,
            updatedAt: event.timestamp,
            origin: .hook
        )
    }
}

public struct GitCheckout: Sendable, Equatable {
    public var branch: String?
    public var isLinkedWorktree: Bool

    public init(branch: String?, isLinkedWorktree: Bool) {
        self.branch = branch
        self.isLinkedWorktree = isLinkedWorktree
    }
}

public struct GitInspector: Sendable {
    public var run: @Sendable (_ arguments: [String], _ directory: URL) -> String?

    public init(run: @escaping @Sendable (_ arguments: [String], _ directory: URL) -> String?) {
        self.run = run
    }

    public static func live() -> GitInspector {
        GitInspector { arguments, directory in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return nil
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
    }

    public func describe(cwd: URL) -> GitCheckout {
        let branch = run(["rev-parse", "--abbrev-ref", "HEAD"], cwd)
        let gitDir = run(["rev-parse", "--git-dir"], cwd)
        let common = run(["rev-parse", "--git-common-dir"], cwd)
        let linked = gitDir != nil && common != nil && gitDir != common
        let name = branch == "HEAD" ? nil : branch
        return GitCheckout(branch: name, isLinkedWorktree: linked)
    }
}
