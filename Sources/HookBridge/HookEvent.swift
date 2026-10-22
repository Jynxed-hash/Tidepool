import Foundation

/// A hook event safe to keep on disk. Prompt bodies are dropped.
public struct HookEvent: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var hook: String
    public var sessionID: String
    public var cwd: String?
    public var transcriptPath: String?
    public var notificationType: String?
    public var message: String?
    public var toolName: String?
    public var toolDetail: String?
    public var backgroundTaskCount: Int?
    public var endReason: String?

    public init(
        timestamp: Date,
        hook: String,
        sessionID: String,
        cwd: String? = nil,
        transcriptPath: String? = nil,
        notificationType: String? = nil,
        message: String? = nil,
        toolName: String? = nil,
        toolDetail: String? = nil,
        backgroundTaskCount: Int? = nil,
        endReason: String? = nil
    ) {
        self.timestamp = timestamp
        self.hook = hook
        self.sessionID = sessionID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.notificationType = notificationType
        self.message = message
        self.toolName = toolName
        self.toolDetail = toolDetail
        self.backgroundTaskCount = backgroundTaskCount
        self.endReason = endReason
    }
}

public enum HookIngest {
    /// Parses Claude Code's hook stdin. Returns nil for empty or unusable input.
    /// The `prompt` field is ignored on purpose.
    public static func event(from data: Data, now: Date) -> HookEvent? {
        guard !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let hook = string(json["hook_event_name"]) ?? ""
        let session = string(json["session_id"]) ?? ""
        guard !hook.isEmpty, !session.isEmpty else { return nil }

        let toolName = string(json["tool_name"])
        let toolInput = json["tool_input"] as? [String: Any]
        let (detail, _) = toolDetail(name: toolName, input: toolInput)
        let message = clipped(string(json["message"]), limit: 160)
        let background = (json["background_tasks"] as? [Any])?.count

        return HookEvent(
            timestamp: now,
            hook: hook,
            sessionID: session,
            cwd: string(json["cwd"]),
            transcriptPath: string(json["transcript_path"]),
            notificationType: string(json["notification_type"]),
            message: message,
            toolName: toolName,
            toolDetail: detail,
            backgroundTaskCount: background,
            endReason: string(json["reason"])
        )
    }

    static func toolDetail(name: String?, input: [String: Any]?) -> (String?, Bool) {
        guard input != nil || name != nil else { return (nil, false) }
        if let command = string(input?["command"]), !command.isEmpty {
            let firstLine = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
            return (clip(firstLine.trimmingCharacters(in: .whitespaces), limit: 80), true)
        }
        if let description = string(input?["description"]), !description.isEmpty {
            return (clip(description, limit: 80), false)
        }
        if let file = string(input?["file_path"]) ?? string(input?["path"]) {
            return (URL(fileURLWithPath: file).lastPathComponent, false)
        }
        return (nil, false)
    }

    private static func string(_ value: Any?) -> String? {
        guard let value, let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func clipped(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        return clip(text, limit: limit)
    }

    private static func clip(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}

public struct EventLog {
    public var fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func append(_ event: HookEvent) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(event)
        data.append(0x0A)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
_ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    public func readAll() throws -> [HookEvent] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var events: [HookEvent] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let event = try? decoder.decode(HookEvent.self, from: Data(line)) {
                events.append(event)
            }
        }
        return events
    }
}
