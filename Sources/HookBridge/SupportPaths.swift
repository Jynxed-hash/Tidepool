import Foundation

public enum TidepoolPaths {
    public static func supportDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment["TIDEPOOL_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Application Support/Tidepool", isDirectory: true)
    }

    public static func eventsFile(support: URL) -> URL {
        support.appendingPathComponent("events.ndjson")
    }

    public static func statuslineFile(support: URL) -> URL {
        support.appendingPathComponent("statusline.json")
    }

    public static func statuslineChainFile(support: URL) -> URL {
        support.appendingPathComponent("statusline-chain.json")
    }

    public static func hookBinary(support: URL) -> URL {
        support.appendingPathComponent("cmb-hook")
    }
}

public enum HookMarker {
    /// Commands we wrote. The binary always lives under Application Support/Tidepool.
    public static func isOurs(_ command: String) -> Bool {
        command.contains("/Tidepool/cmb-hook")
    }
}
