import Foundation

public struct HookInstallPlan: Sendable, Equatable {
    public var hookCommand: String
    public var chainStatusline: Bool

    public init(hookCommand: String, chainStatusline: Bool = true) {
        self.hookCommand = hookCommand
        self.chainStatusline = chainStatusline
    }
}

public struct HookInstallOutcome: Sendable, Equatable {
    public var changed: Bool
    public var backupURL: URL?
    /// The user's previous status-line command, when we replaced one.
    public var previousStatuslineCommand: String?
    public var replacedStatusline: Bool

    public init(changed: Bool, backupURL: URL?, previousStatuslineCommand: String? = nil, replacedStatusline: Bool = false) {
        self.changed = changed
        self.backupURL = backupURL
        self.previousStatuslineCommand = previousStatuslineCommand
        self.replacedStatusline = replacedStatusline
    }
}

public enum HookSettingsError: Error, Equatable {
    case invalidJSON
    case notADictionary
}

public enum HookSettings {
    public static let managedEvents = [
        "Notification",
        "PermissionRequest",
        "Stop",
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
    ]

    public static func isInstalled(at settingsURL: URL) -> Bool {
        guard let root = try? load(settingsURL) else { return false }
        return containsOurHook(root)
    }

    public static func install(
        settingsURL: URL,
        backupDirectory: URL,
        plan: HookInstallPlan,
        now: Date,
        fileManager: FileManager = .default
    ) throws -> HookInstallOutcome {
        let existed = fileManager.fileExists(atPath: settingsURL.path)
        let original = existed ? try Data(contentsOf: settingsURL) : nil
        let root: [String: Any]
        if let original, !original.isEmpty {
            root = try load(settingsURL)
        } else {
            root = [:]
        }
        var edited = root
        mergeHooks(&edited, command: plan.hookCommand)
        let status = mergeStatusline(&edited, command: plan.hookCommand, enabled: plan.chainStatusline)
        return try commit(
            original: original,
            root: root,
            edited: edited,
            settingsURL: settingsURL,
            backupDirectory: backupDirectory,
            now: now,
            previousStatusline: status.previous,
            replacedStatusline: status.replaced,
            fileManager: fileManager
        )
    }

    public static func uninstall(
        settingsURL: URL,
        backupDirectory: URL,
        restoreStatuslineCommand: String?,
        now: Date,
        fileManager: FileManager = .default
    ) throws -> HookInstallOutcome {
        guard fileManager.fileExists(atPath: settingsURL.path) else {
            return HookInstallOutcome(changed: false, backupURL: nil)
        }
        var edited = try load(settingsURL)
        let root = edited
        removeOurHooks(&edited)
        restoreStatusline(&edited, command: restoreStatuslineCommand)
        return try commit(
            original: try Data(contentsOf: settingsURL),
            root: root,
            edited: edited,
            settingsURL: settingsURL,
            backupDirectory: backupDirectory,
            now: now,
            previousStatusline: nil,
            replacedStatusline: false,
            fileManager: fileManager
        )
    }

    private static func commit(
        original: Data?,
        root: [String: Any],
        edited: [String: Any],
        settingsURL: URL,
        backupDirectory: URL,
        now: Date,
        previousStatusline: String?,
        replacedStatusline: Bool,
        fileManager: FileManager
    ) throws -> HookInstallOutcome {
        let before = try canonical(root)
        let after = try canonical(edited)
        guard before != after else {
            return HookInstallOutcome(changed: false, backupURL: nil)
        }
        var backupURL: URL?
        if let original {
            backupURL = try writeBackup(original, directory: backupDirectory, now: now, fileManager: fileManager)
        }
        try write(edited, to: settingsURL, preserving: settingsURL, fileManager: fileManager)
        return HookInstallOutcome(
            changed: true,
            backupURL: backupURL,
            previousStatuslineCommand: previousStatusline,
            replacedStatusline: replacedStatusline
        )
    }

    static func load(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw HookSettingsError.invalidJSON
        }
        guard let dictionary = object as? [String: Any] else {
            throw HookSettingsError.notADictionary
        }
        return dictionary
    }

    private static func containsOurHook(_ root: [String: Any]) -> Bool {
        guard let hooks = root["hooks"] as? [String: Any] else { return false }
        for value in hooks.values {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else { continue }
                if handlers.contains(where: { HookMarker.isOurs($0["command"] as? String ?? "") }) {
                    return true
                }
            }
        }
        return false
    }

    private static func mergeHooks(_ root: inout [String: Any], command: String) {
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in managedEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups = groups.compactMap { group in
                var copy = group
                let handlers = (group["hooks"] as? [[String: Any]] ?? []).filter {
                    !HookMarker.isOurs($0["command"] as? String ?? "")
                }
                if handlers.isEmpty { return nil }
                copy["hooks"] = handlers
                return copy
            }
            groups.append(ourGroup(event: event, command: command))
            hooks[event] = groups
        }
        root["hooks"] = hooks
    }

    private static func removeOurHooks(_ root: inout [String: Any]) {
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for key in Array(hooks.keys) {
            guard var groups = hooks[key] as? [[String: Any]] else { continue }
            groups = groups.compactMap { group in
                var copy = group
                let handlers = (group["hooks"] as? [[String: Any]] ?? []).filter {
                    !HookMarker.isOurs($0["command"] as? String ?? "")
                }
                if handlers.isEmpty { return nil }
                copy["hooks"] = handlers
                return copy
            }
            if groups.isEmpty {
                hooks.removeValue(forKey: key)
            } else {
                hooks[key] = groups
            }
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
    }

    private static func ourGroup(event: String, command: String) -> [String: Any] {
        let handler: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": 5,
        ]
        var group: [String: Any] = ["hooks": [handler]]
        if event == "Notification" {
            group["matcher"] = "permission_prompt|idle_prompt|agent_needs_input"
        }
        return group
    }

    private struct StatuslineMerge {
        var previous: String?
        var replaced: Bool
    }

    private static func mergeStatusline(_ root: inout [String: Any], command: String, enabled: Bool) -> StatuslineMerge {
        guard enabled else { return StatuslineMerge(previous: nil, replaced: false) }
        let ours = command + " statusline"
        if let existing = root["statusLine"] as? [String: Any] {
            let current = existing["command"] as? String ?? ""
            if HookMarker.isOurs(current) {
                return StatuslineMerge(previous: nil, replaced: false)
            }
            let type = existing["type"] as? String
            if type == "command", !current.isEmpty {
                root["statusLine"] = ["type": "command", "command": ours]
                return StatuslineMerge(previous: current, replaced: true)
            }
            return StatuslineMerge(previous: nil, replaced: false)
        }
        root["statusLine"] = ["type": "command", "command": ours]
        return StatuslineMerge(previous: nil, replaced: true)
    }

    private static func restoreStatusline(_ root: inout [String: Any], command: String?) {
        guard let existing = root["statusLine"] as? [String: Any] else { return }
        let current = existing["command"] as? String ?? ""
        guard HookMarker.isOurs(current) else { return }
        if let command, !command.isEmpty {
            root["statusLine"] = ["type": "command", "command": command]
        } else {
            root.removeValue(forKey: "statusLine")
        }
    }

    private static func canonical(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func write(_ object: [String: Any], to url: URL, preserving original: URL, fileManager: FileManager) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let temp = directory.appendingPathComponent(".tidepool-settings-\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        if fileManager.fileExists(atPath: original.path),
           let permissions = try? fileManager.attributesOfItem(atPath: original.path)[.posixPermissions] {
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
        }
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.moveItem(at: temp, to: url)
    }

    private static func writeBackup(_ data: Data, directory: URL, now: Date, fileManager: FileManager) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("settings-\(backupName(now: now)).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func backupName(now: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: now).replacingOccurrences(of: ":", with: "")
    }
}

public struct StatuslineChain: Codable, Equatable, Sendable {
    public var command: String

    public init(command: String) {
        self.command = command
    }

    public static func load(from url: URL) -> StatuslineChain? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StatuslineChain.self, from: data)
    }

    public func save(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}
