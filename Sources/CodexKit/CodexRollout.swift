import Foundation
import ProviderKit

public enum CodexRollout {
    static let sessionHorizon: TimeInterval = 12 * 60 * 60
    static let rateLimitLookbackDays = 14

    public struct FileParse: Equatable {
        var session: TrackedSession?
        var windows: [UsageWindow]
        var limitsAt: Date?
    }

    static func codexHome(request: ProviderRefreshRequest) -> URL {
        if let value = request.environment["CODEX_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return request.home.appendingPathComponent(".codex", isDirectory: true)
    }

    public static func load(
        codexHome: URL,
        now: Date,
        calendar: Calendar = .current,
        fileManager: FileManager = .default
    ) -> (sessions: [TrackedSession], windows: [UsageWindow]) {
        var sessions: [TrackedSession] = []
        var best: (Date, [UsageWindow])?
        for url in rolloutFiles(codexHome: codexHome, now: now, calendar: calendar, fileManager: fileManager) {
            guard let data = try? Data(contentsOf: url) else { continue }
            let parsed = parse(data, now: now)
            if let session = parsed.session, now.timeIntervalSince(session.updatedAt) <= sessionHorizon {
                sessions.append(session)
            }
            if let at = parsed.limitsAt, !parsed.windows.isEmpty {
                if best == nil || at > best!.0 {
                    best = (at, parsed.windows)
                }
            }
        }
        sessions.sort(by: sortSessions)
        return (sessions, best?.1 ?? [])
    }

    public static func parse(_ data: Data, now: Date) -> FileParse {
        var id: String?
        var cwd: String?
        var updated = Date.distantPast
        var activity: SessionActivity = .idle
        var sawTurn = false
        var windows: [UsageWindow] = []
        var limitsAt: Date?
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            guard let object = CodexJSON.object(Data(line.utf8)) else { continue }
            let timestamp = CodexJSON.date(object["timestamp"]) ?? now
            guard let payload = CodexJSON.dictionary(object["payload"]) else { continue }
            switch CodexJSON.string(object["type"]) {
            case "session_meta":
                id = CodexJSON.string(payload["id"]) ?? CodexJSON.string(payload["session_id"]) ?? id
                cwd = CodexJSON.string(payload["cwd"]) ?? cwd
                if timestamp > updated { updated = timestamp }
            case "event_msg":
                let kind = CodexJSON.string(payload["type"])
                switch kind {
                case "task_started", "turn_started":
                    activity = .working
                    sawTurn = true
                    if timestamp > updated { updated = timestamp }
                case "task_complete", "turn_complete", "turn_aborted":
                    activity = .idle
                    sawTurn = true
                    if timestamp > updated { updated = timestamp }
                case "token_count":
                    if let limits = CodexJSON.dictionary(payload["rate_limits"]) {
                        let parsed = CodexWindows.windows(from: limits, origin: .server)
                        if !parsed.isEmpty {
                            windows = parsed
                            limitsAt = timestamp
                        }
                    }
                    if timestamp > updated { updated = timestamp }
                default:
                    break
                }
            default:
                break
            }
        }
        guard let id else { return FileParse(session: nil, windows: windows, limitsAt: limitsAt) }
        let session = TrackedSession(
            id: id,
            repo: repoName(cwd) ?? "session",
            cwd: cwd,
            activity: sawTurn ? activity : .idle,
            updatedAt: updated == .distantPast ? now : updated,
            origin: .estimate
        )
        return FileParse(session: session, windows: windows, limitsAt: limitsAt)
    }

    static func rolloutFiles(
        codexHome: URL,
        now: Date,
        calendar: Calendar,
        fileManager: FileManager
    ) -> [URL] {
        var files: [URL] = []
        for offset in 0..<rateLimitLookbackDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayNumber = parts.day else { continue }
            let directory = codexHome
                .appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", dayNumber), isDirectory: true)
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                files.append(directory.appendingPathComponent(name))
            }
        }
        return files
    }

    private static func repoName(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func sortSessions(_ lhs: TrackedSession, _ rhs: TrackedSession) -> Bool {
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
