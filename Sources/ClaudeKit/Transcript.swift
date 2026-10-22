import Foundation

public struct TokenUsage: Sendable, Equatable, Codable {
    public var input: Int
    public var output: Int
    public var cacheCreation: Int
    public var cacheRead: Int
    public var cache5m: Int?
    public var cache1h: Int?

    public init(
        input: Int = 0,
        output: Int = 0,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        cache5m: Int? = nil,
        cache1h: Int? = nil
    ) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
        self.cache5m = cache5m
        self.cache1h = cache1h
    }

    public var total: Int { input + output + cacheCreation + cacheRead }
}

public struct TranscriptEntry: Sendable, Equatable, Identifiable {
    public var id: String
    public var messageID: String?
    public var requestID: String?
    public var sessionID: String?
    public var timestamp: Date?
    public var cwd: String?
    public var gitBranch: String?
    public var role: String?
    public var model: String?
    public var usage: TokenUsage?
    /// True when this line is the latest one we will keep for its dedupe key.
    public var isLastInSessionFile: Bool

    public init(
        id: String,
        messageID: String? = nil,
        requestID: String? = nil,
        sessionID: String? = nil,
        timestamp: Date? = nil,
        cwd: String? = nil,
        gitBranch: String? = nil,
        role: String? = nil,
        model: String? = nil,
        usage: TokenUsage? = nil,
        isLastInSessionFile: Bool = false
    ) {
        self.id = id
        self.messageID = messageID
        self.requestID = requestID
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.role = role
        self.model = model
        self.usage = usage
        self.isLastInSessionFile = isLastInSessionFile
    }
}

public enum TranscriptParser {
    /// Reads usage, cwd, branch, role, and ids. Message text is not kept.
    public static func parse(_ data: Data) -> [TranscriptEntry] {
        var entries: [TranscriptEntry] = []
        var index = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            index += 1
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                continue
            }
            let message = object["message"] as? [String: Any]
            let usage = usage(from: message?["usage"])
            let role = message?["role"] as? String ?? object["type"] as? String
            let messageID = message?["id"] as? String
            let requestID = object["requestId"] as? String ?? object["request_id"] as? String
            let sessionID = object["sessionId"] as? String ?? object["session_id"] as? String
            let identity = messageID ?? object["uuid"] as? String ?? "line-\(index)"
            entries.append(TranscriptEntry(
                id: identity,
                messageID: messageID,
                requestID: requestID,
                sessionID: sessionID,
                timestamp: JSONDates.parse(object["timestamp"]),
                cwd: object["cwd"] as? String,
                gitBranch: object["gitBranch"] as? String ?? object["git_branch"] as? String,
                role: role,
                model: modelName(message?["model"]),
                usage: usage
            ))
        }
        if !entries.isEmpty {
            entries[entries.count - 1].isLastInSessionFile = true
        }
        return entries
    }

    /// Keeps one entry per message id + request id. The copy with the larger
    /// output count wins, which is the later streaming snapshot.
    public static func dedupe(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
        struct Key: Hashable {
            var message: String
            var request: String
        }
        var keyed: [Key: TranscriptEntry] = [:]
        var passthrough: [TranscriptEntry] = []
        for entry in entries {
            guard let message = entry.messageID, let request = entry.requestID else {
                passthrough.append(entry)
                continue
            }
            let key = Key(message: message, request: request)
            if let existing = keyed[key] {
                let existingOutput = existing.usage?.output ?? -1
                let newOutput = entry.usage?.output ?? -1
                if newOutput >= existingOutput {
                    var replacement = entry
                    replacement.isLastInSessionFile = existing.isLastInSessionFile || entry.isLastInSessionFile
                    keyed[key] = replacement
                }
            } else {
                keyed[key] = entry
            }
        }
        return passthrough + keyed.values
    }

    private static func usage(from value: Any?) -> TokenUsage? {
        guard let object = value as? [String: Any] else { return nil }
        let input = JSONNumbers.int(object["input_tokens"]) ?? 0
        let output = JSONNumbers.int(object["output_tokens"]) ?? 0
        let cacheCreation = JSONNumbers.int(object["cache_creation_input_tokens"]) ?? 0
        let cacheRead = JSONNumbers.int(object["cache_read_input_tokens"]) ?? 0
        var cache5m: Int?
        var cache1h: Int?
        if let split = object["cache_creation"] as? [String: Any] {
            cache5m = JSONNumbers.int(split["ephemeral_5m_input_tokens"])
            cache1h = JSONNumbers.int(split["ephemeral_1h_input_tokens"])
        }
        if input == 0, output == 0, cacheCreation == 0, cacheRead == 0 { return nil }
        return TokenUsage(
            input: input,
            output: output,
            cacheCreation: cacheCreation,
            cacheRead: cacheRead,
            cache5m: cache5m,
            cache1h: cache1h
        )
    }

    private static func modelName(_ value: Any?) -> String? {
        if let name = value as? String, !name.isEmpty { return name }
        if let object = value as? [String: Any] {
            if let id = object["id"] as? String, !id.isEmpty { return id }
        }
        return nil
    }
}

public struct TranscriptHint: Sendable, Equatable {
    public var sessionID: String
    public var cwd: String?
    public var gitBranch: String?
    public var lastRole: String?
    public var lastTimestamp: Date?

    public init(sessionID: String, cwd: String?, gitBranch: String?, lastRole: String?, lastTimestamp: Date?) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.lastRole = lastRole
        self.lastTimestamp = lastTimestamp
    }
}

public enum TranscriptFiles {
    public static func sessionFiles(in projects: URL, fileManager: FileManager = .default) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: projects,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            if url.path.contains("/subagents/") { continue }
            files.append(url)
        }
        return files
    }

    public static func loadRecent(
        projects: URL,
        notBefore: Date,
        fileManager: FileManager = .default
    ) -> [TranscriptEntry] {
        var combined: [TranscriptEntry] = []
        for url in sessionFiles(in: projects, fileManager: fileManager) {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < notBefore { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            let parsed = TranscriptParser.parse(data)
            let session = url.deletingPathExtension().lastPathComponent
            combined.append(contentsOf: parsed.map { entry in
                var copy = entry
                if copy.sessionID == nil { copy.sessionID = session }
                return copy
            })
        }
        return TranscriptParser.dedupe(combined)
    }
}
