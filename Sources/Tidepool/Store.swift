import ClaudeKit
import Foundation
import HookBridge
import ProviderKit
import SwiftUI
import UserNotifications

enum MenuBarFormat: String, CaseIterable, Identifiable {
    case symbolPercent
    case symbol
    case symbolPercentReset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .symbolPercent: "Symbol and percent"
        case .symbol: "Symbol only"
        case .symbolPercentReset: "Symbol, percent, and reset"
        }
    }
}

enum PreferenceKey {
    static let format = "tidepool.menuFormat"
    static let notifications = "tidepool.notifications"
    static let hooks = "tidepool.hooks"
    static let refresh = "tidepool.refreshSeconds"
}

@MainActor
@Observable
final class TidepoolStore {
    var snapshot = ProviderSnapshot(providerID: ToolCatalog.claudeCode, checkedAt: .distantPast)
    var catalog: [CatalogStatus] = []
    var menuFormat: MenuBarFormat
    var notificationsEnabled: Bool
    var hooksEnabled: Bool
    var refreshSeconds: Double
    var showingSettings = false
    var expandedSessionID: String?
    var actionNotice: String?
    var launchAtLogin: Bool
    private var notified: Set<String> = []
    private var loop: Task<Void, Never>?
    private var watch: DirectoryWatch?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let format = MenuBarFormat(rawValue: defaults.string(forKey: PreferenceKey.format) ?? "") ?? .symbolPercent
        self.menuFormat = format
        self.notificationsEnabled = defaults.object(forKey: PreferenceKey.notifications) as? Bool ?? true
        self.hooksEnabled = defaults.bool(forKey: PreferenceKey.hooks)
        let stored = defaults.double(forKey: PreferenceKey.refresh)
        self.refreshSeconds = stored >= 60 ? stored : 90
        self.launchAtLogin = LoginItem.enabled
        UNUserNotificationCenter.current().delegate = NotificationHub.presenter
        loop = Task { [weak self] in
            await self?.runLoop()
        }
        startWatch()
    }

    var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    var support: URL { TidepoolPaths.supportDirectory(home: home) }

    var comingSoon: [CatalogStatus] {
        catalog.filter { $0.state == .comingSoon }
    }

    var menuPercent: String? {
        guard menuFormat != .symbol else { return nil }
        guard let window = snapshot.fiveHour else { return nil }
        return "\(Int(window.usedPercent.rounded()))%"
    }

    var menuReset: String? {
        guard menuFormat == .symbolPercentReset, let resets = snapshot.fiveHour?.resetsAt else { return nil }
        return ResetCopy.countdown(resets, now: Date())
            .replacingOccurrences(of: "Resets in ", with: "")
    }

    func runLoop() async {
        var nextNetwork = Date.distantPast
        while !Task.isCancelled {
            let allowNetwork = Date() >= nextNetwork
            await refresh(allowNetwork: allowNetwork)
            if allowNetwork {
                let extra = snapshot.retryAfter ?? 0
                nextNetwork = Date().addingTimeInterval(max(refreshSeconds, extra))
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func refresh(allowNetwork: Bool) async {
        let request = ProviderRefreshRequest(
            now: Date(),
            home: home,
            supportDirectory: support,
            allowNetwork: allowNetwork
        )
        var fresh = await Task.detached(priority: .utility) {
            await LiveClaudeProvider().refresh(request)
        }.value
        // Quiet ticks refresh sessions and today's estimate only. Usage windows
        // stay on the last network result, so a local pass cannot drop the
        // weekly Opus row that the status line does not report.
        if !allowNetwork {
            fresh.windows = snapshot.windows
            fresh.notice = snapshot.notice
            fresh.retryAfter = snapshot.retryAfter
        }
        let input = ToolDetector.probe(
            home: home,
            applicationDirectories: [
                URL(fileURLWithPath: "/Applications"),
                home.appendingPathComponent("Applications"),
                URL(fileURLWithPath: "/System/Applications"),
            ],
            path: ProcessInfo.processInfo.environment["PATH"] ?? "",
            environment: ProcessInfo.processInfo.environment
        )
        catalog = ToolDetector.status(for: input)
        apply(fresh)
    }

    func toggleExpanded(_ id: String) {
        expandedSessionID = expandedSessionID == id ? nil : id
    }

    func focusNeedsYou() {
        guard let session = snapshot.sessions.first(where: { $0.activity == .needsYou }) else { return }
        expandedSessionID = session.id
    }

    func setMenuFormat(_ format: MenuBarFormat) {
        menuFormat = format
        defaults.set(format.rawValue, forKey: PreferenceKey.format)
    }

    func setRefreshSeconds(_ seconds: Double) {
        refreshSeconds = min(600, max(60, seconds))
        defaults.set(refreshSeconds, forKey: PreferenceKey.refresh)
    }

    func setNotifications(enabled: Bool) async {
        if enabled {
            let allowed = await Notifier.authorize()
            notificationsEnabled = allowed
            defaults.set(allowed, forKey: PreferenceKey.notifications)
            if !allowed {
                actionNotice = "Notifications are off in System Settings."
            }
        } else {
            notificationsEnabled = false
            defaults.set(false, forKey: PreferenceKey.notifications)
        }
    }

    func setHooks(enabled: Bool) {
        do {
            if enabled {
                try installHooks()
                hooksEnabled = true
            } else {
                try removeHooks()
                hooksEnabled = false
            }
            defaults.set(hooksEnabled, forKey: PreferenceKey.hooks)
            actionNotice = nil
        } catch {
            actionNotice = "Couldn't update Claude Code hooks."
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
            launchAtLogin = LoginItem.enabled
            actionNotice = nil
        } catch {
            launchAtLogin = LoginItem.enabled
            actionNotice = "Launch at login needs the Tidepool app bundle."
        }
    }

    private func apply(_ fresh: ProviderSnapshot) {
        let previous = Set(snapshot.sessions.filter { $0.activity == .needsYou }.map(\.id))
        snapshot = fresh
        let current = snapshot.sessions.filter { $0.activity == .needsYou }
        let currentIDs = Set(current.map(\.id))
        notified.subtract(notified.subtracting(currentIDs))
        guard notificationsEnabled else { return }
        for session in current where !previous.contains(session.id) && !notified.contains(session.id) {
            notified.insert(session.id)
            guard session.updatedAt.timeIntervalSinceNow > -120 else { continue }
            Task { await notify(session) }
        }
    }

    private func notify(_ session: TrackedSession) async {
        guard await Notifier.authorize() else { return }
        Notifier.post(session)
    }

    private func installHooks() throws {
        guard let source = HookLocator.binary() else {
            throw CocoaError(.fileNoSuchFile)
        }
        let destination = TidepoolPaths.hookBinary(support: support)
        let manager = FileManager.default
        try manager.createDirectory(at: support, withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.copyItem(at: source, to: destination)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        let outcome = try HookSettings.install(
            settingsURL: home.appendingPathComponent(".claude/settings.json"),
            backupDirectory: home.appendingPathComponent(".claude/tidepool-backups"),
            plan: HookInstallPlan(hookCommand: destination.path, chainStatusline: true),
            now: Date()
        )
        if outcome.replacedStatusline {
            try StatuslineChain(command: outcome.previousStatuslineCommand ?? "").save(
                to: TidepoolPaths.statuslineChainFile(support: support)
            )
        }
    }

    private func removeHooks() throws {
        let chain = StatuslineChain.load(from: TidepoolPaths.statuslineChainFile(support: support))
        _ = try HookSettings.uninstall(
            settingsURL: home.appendingPathComponent(".claude/settings.json"),
            backupDirectory: home.appendingPathComponent(".claude/tidepool-backups"),
            restoreStatuslineCommand: chain?.command,
            now: Date()
        )
        let chainURL = TidepoolPaths.statuslineChainFile(support: support)
        if FileManager.default.fileExists(atPath: chainURL.path) {
            try? FileManager.default.removeItem(at: chainURL)
        }
    }

    private func startWatch() {
        let projects = home.appendingPathComponent(".claude/projects").path
        let events = TidepoolPaths.eventsFile(support: support).deletingLastPathComponent().path
        let watcher = DirectoryWatch()
        watcher.start(paths: [projects, events]) { [weak self] in
            Task { @MainActor in
                await self?.refresh(allowNetwork: false)
            }
        }
        watch = watcher
    }
}

enum HookLocator {
    static func binary() -> URL? {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "cmb-hook") {
            return bundled
        }
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("cmb-hook")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        return nil
    }
}
