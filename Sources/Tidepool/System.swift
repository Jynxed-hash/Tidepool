import AppKit
import CoreServices
import Foundation
import ProviderKit
import ServiceManagement
import UserNotifications

enum LoginItem {
    static var enabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

enum Notifier {
    static func authorize() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default:
            return false
        }
    }

    static func post(_ session: TrackedSession) {
        let content = UNMutableNotificationContent()
        content.title = "\(session.repo) needs you"
        if let branch = session.branch {
            content.body = "Claude is waiting for permission on \(branch)"
        } else if let detail = session.waitingDetail {
            content.body = "Claude is waiting for permission: \(detail)"
        } else {
            content.body = "Claude is waiting"
        }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "tidepool-needs-\(session.id)-\(Int(session.updatedAt.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

enum SessionOpener {
    static func openTerminal(_ cwd: String) {
        let escaped = cwd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "cd " & quoted form of "\(escaped)"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    static func openCursor(_ cwd: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Cursor", cwd]
        try? process.run()
    }
}

/// File-event watcher. The stream callback runs on the main queue.
/// `@unchecked Sendable` lets that callback hop back onto the main actor.
final class DirectoryWatch: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private var onChange: @MainActor () -> Void = {}

    func start(paths: [String], onChange: @escaping @MainActor () -> Void) {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            UInt32(kFSEventStreamCreateFlagFileEvents) | UInt32(kFSEventStreamCreateFlagUseCFTypes)
        )
        guard let created = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let watch = Unmanaged<DirectoryWatch>.fromOpaque(info).takeUnretainedValue()
                Task { @MainActor in
                    watch.onChange()
                }
            },
            &context,
            existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, .main)
        FSEventStreamStart(created)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
