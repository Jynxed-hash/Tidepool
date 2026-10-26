import Foundation
import ProviderKit

public struct CodexLiveSnapshot: Sendable, Equatable {
    public var windows: [UsageWindow]?
    public var sessions: [TrackedSession]?
    public var todayTokens: Int?

    public init(windows: [UsageWindow]? = nil, sessions: [TrackedSession]? = nil, todayTokens: Int? = nil) {
        self.windows = windows
        self.sessions = sessions
        self.todayTokens = todayTokens
    }
}

public protocol CodexLiveReading: Sendable {
    func read(environment: [String: String], now: Date) async -> CodexLiveSnapshot?
}

public struct StaticCodexLive: CodexLiveReading {
    public var snapshot: CodexLiveSnapshot?
    public init(snapshot: CodexLiveSnapshot?) { self.snapshot = snapshot }
    public func read(environment: [String: String], now: Date) async -> CodexLiveSnapshot? { snapshot }
}

public enum CodexAppServer {
    static let sessionHorizon: TimeInterval = CodexRollout.sessionHorizon

    /// Methods this client sends. It does not log in, read the account token, or redeem a reset.
    public static func outboundJSON() -> [String] {
        [
            encode(initialize()),
            encode(initialized()),
            encode(request(id: 2, method: "account/rateLimits/read")),
            encode(request(id: 3, method: "thread/list", params: ["limit": 25, "sortKey": "updated_at", "archived": false])),
            encode(request(id: 4, method: "account/usage/read")),
        ].compactMap { $0 }
    }

    public static func parseMessages(_ lines: [String], now: Date, calendar: Calendar = .current) -> CodexLiveSnapshot {
        var snapshot = CodexLiveSnapshot()
        for line in lines {
            guard let object = CodexJSON.object(Data(line.utf8)) else { continue }
            guard let id = CodexJSON.int(object["id"]) else { continue }
            if object["error"] != nil {
                continue
            }
            guard let result = CodexJSON.dictionary(object["result"]) else { continue }
            switch id {
            case 2:
                snapshot.windows = CodexWindows.windows(fromAppServerResult: result)
            case 3:
                snapshot.sessions = threads(from: result, now: now)
            case 4:
                snapshot.todayTokens = todayTokens(from: result, now: now, calendar: calendar)
            default:
                break
            }
        }
        return snapshot
    }

    static func threads(from result: [String: Any], now: Date) -> [TrackedSession] {
        let rows = result["data"] as? [Any] ?? []
        var sessions: [TrackedSession] = []
        for row in rows {
            guard let thread = row as? [String: Any] else { continue }
            guard let id = CodexJSON.string(thread["id"]) else { continue }
            guard let updated = CodexJSON.date(thread["updatedAt"] ?? thread["createdAt"]) else { continue }
            guard now.timeIntervalSince(updated) <= sessionHorizon else { continue }
            let status = CodexJSON.dictionary(thread["status"])
            let kind = CodexJSON.string(status?["type"]) ?? "notLoaded"
            let flags = CodexJSON.strings(status?["activeFlags"])
            let activity: SessionActivity
            var waiting: String?
            if kind == "active", flags.contains("waitingOnApproval") {
                activity = .needsYou
                waiting = "Waiting on approval"
            } else if kind == "active" {
                activity = .working
            } else {
                activity = .idle
            }
            let cwd = CodexJSON.string(thread["cwd"])
            let branch = CodexJSON.string(CodexJSON.dictionary(thread["gitInfo"])?["branch"])
            let repo = repoName(cwd) ?? CodexJSON.string(thread["name"]) ?? "session"
            sessions.append(TrackedSession(
                id: id,
                repo: repo,
                branch: branch,
                cwd: cwd,
                activity: activity,
                waitingDetail: waiting,
                updatedAt: updated,
                origin: .server
            ))
        }
        return sessions.sorted { lhs, rhs in
            func rank(_ activity: SessionActivity) -> Int {
                switch activity {
                case .needsYou: return 0
                case .working: return 1
                case .idle: return 2
                }
            }
            if rank(lhs.activity) != rank(rhs.activity) { return rank(lhs.activity) < rank(rhs.activity) }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    static func todayTokens(from result: [String: Any], now: Date, calendar: Calendar) -> Int? {
        guard let buckets = result["dailyUsageBuckets"] as? [Any] else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        for bucket in buckets {
            guard let object = bucket as? [String: Any] else { continue }
            guard CodexJSON.string(object["startDate"]) == today else { continue }
            return CodexJSON.int(object["tokens"])
        }
        return nil
    }

    static func locateExecutable(path: String, fileManager: FileManager = .default) -> String? {
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("codex")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    private static func initialize() -> [String: Any] {
        [
            "method": "initialize",
            "id": 1,
            "params": [
                "clientInfo": [
                    "name": "tidepool",
                    "title": "Tidepool",
                    "version": "0.1.0",
                ],
            ],
        ]
    }

    private static func initialized() -> [String: Any] {
        ["method": "initialized"]
    }

    private static func request(id: Int, method: String, params: [String: Any]? = nil) -> [String: Any] {
        var message: [String: Any] = ["method": method, "id": id]
        if let params { message["params"] = params }
        return message
    }

    private static func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func repoName(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? nil : name
    }
}

public struct CodexProcessReader: CodexLiveReading {
    public init() {}

    public func read(environment: [String: String], now: Date) async -> CodexLiveSnapshot? {
        guard let executable = CodexAppServer.locateExecutable(path: environment["PATH"] ?? "") else { return nil }
        let lines = await CodexAppServerProcess.exchange(executable: executable)
        guard !lines.isEmpty else { return nil }
        let snapshot = CodexAppServer.parseMessages(lines, now: now)
        if snapshot.windows == nil, snapshot.sessions == nil, snapshot.todayTokens == nil {
            return nil
        }
        return snapshot
    }
}

enum CodexAppServerProcess {
    static func exchange(executable: String, timeout: TimeInterval = 8) async -> [String] {
        await Task.detached(priority: .utility) {
            run(executable: executable, timeout: timeout)
        }.value
    }

    private static func run(executable: String, timeout: TimeInterval) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let reader = LineBuffer()
        do {
            try process.run()
        } catch {
            return []
        }
        reader.start(stdout.fileHandleForReading)
        let messages = CodexAppServer.outboundJSON()
        guard messages.count >= 2 else {
            finish(process)
            return []
        }
        write(messages[0], to: stdin)
        let deadline = Date().addingTimeInterval(timeout)
        var sawInitialize = false
        var lines: [String] = []
        while Date() < deadline {
            if let line = reader.pop() {
                lines.append(line)
                if !sawInitialize, responseIDs(lines).contains(1) {
                    sawInitialize = true
                    for message in messages.dropFirst() {
                        write(message, to: stdin)
                    }
                }
            } else {
                Thread.sleep(forTimeInterval: 0.02)
            }
            let ids = responseIDs(lines)
            if sawInitialize, ids.contains(2), ids.contains(3), ids.contains(4) { break }
        }
        finish(process)
        reader.stop()
        lines.append(contentsOf: reader.drain())
        return lines
    }

    private static func responseIDs(_ lines: [String]) -> Set<Int> {
        var ids: Set<Int> = []
        for line in lines {
            guard let object = CodexJSON.object(Data(line.utf8)), let id = CodexJSON.int(object["id"]) else { continue }
            ids.insert(id)
        }
        return ids
    }

    private static func write(_ line: String, to pipe: Pipe) {
        var data = Data(line.utf8)
        data.append(0x0A)
        pipe.fileHandleForWriting.write(data)
    }

    private static func finish(_ process: Process) {
        if process.isRunning {
            process.terminate()
        }
    }
}

final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var lines: [String] = []
    private var handle: FileHandle?

    func start(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.append(data)
        }
    }

    func stop() {
        handle?.readabilityHandler = nil
    }

    func pop() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !lines.isEmpty else { return nil }
        return lines.removeFirst()
    }

    func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let copy = lines
        lines.removeAll()
        return copy
    }

    private func append(_ data: Data) {
        lock.lock()
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let chunk = pending.prefix(upTo: newline)
            pending.removeSubrange(...newline)
            let line = String(decoding: chunk, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(line) }
        }
        lock.unlock()
    }
}
