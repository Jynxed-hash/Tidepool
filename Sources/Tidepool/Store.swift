import ClaudeKit
import CodexKit
import Foundation
import GrokKit
import HookBridge
import MeterKit
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
    static let provider = "tidepool.provider"
}

@MainActor
@Observable
final class TidepoolStore {
    private var snapshots: [String: ProviderSnapshot] = [:]
    var selectedProviderID: String
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
        let storedProvider = defaults.string(forKey: PreferenceKey.provider) ?? ToolCatalog.claudeCode
        self.selectedProviderID = storedProvider
        UNUserNotificationCenter.current().delegate = NotificationHub.presenter
        loop = Task { [weak self] in
            await self?.runLoop()
        }
        startWatch()
    }

    var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    var support: URL { TidepoolPaths.supportDirectory(home: home) }

    var snapshot: ProviderSnapshot {
        snapshots[selectedProviderID] ?? ProviderSnapshot(providerID: selectedProviderID, checkedAt: .distantPast)
    }

    var comingSoon: [CatalogStatus] {
        catalog.filter { $0.state == .comingSoon }
    }

    var providerChoices: [CatalogStatus] {
        catalog.filter { status in
            if status.id == ToolCatalog.claudeCode { return true }
            return status.state == .active || status.state == .limitedData
        }
    }

    var selectedTitle: String {
        if let match = providerChoices.first(where: { $0.id == selectedProviderID }) {
            return match.displayName
        }
        if selectedProviderID == ToolCatalog.claudeCode { return "Claude Code" }
        return "Tidepool"
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

    func selectProvider(_ id: String) {
        selectedProviderID = id
        defaults.set(id, forKey: PreferenceKey.provider)
        expandedSessionID = nil
    }

    func refresh(allowNetwork: Bool) async {
        let environment = ProcessInfo.processInfo.environment
        let request = ProviderRefreshRequest(
            now: Date(),
            home: home,
            supportDirectory: support,
            allowNetwork: allowNetwork,
            environment: environment
        )
        let previous = snapshots
        let fetched = await Task.detached(priority: .utility) {
            async let claudeSnapshot = LiveClaudeProvider().refresh(request)
            async let codexSnapshot = LiveCodexProvider().refresh(request)
            async let grokSnapshot = GrokBotProvider().refresh(request)
            async let openRouterSnapshot = LiveOpenRouterProvider().refresh(request)
            async let geminiSnapshot = LiveGeminiProvider().refresh(request)
            async let openCodeSnapshot = LiveOpenCodeProvider().refresh(request)
            async let zaiSnapshot = LiveZAIProvider().refresh(request)
            async let deepSeekSnapshot = LiveDeepSeekProvider().refresh(request)
            return [
                await claudeSnapshot,
                await codexSnapshot,
                await grokSnapshot,
                await openRouterSnapshot,
                await geminiSnapshot,
                await openCodeSnapshot,
                await zaiSnapshot,
                await deepSeekSnapshot,
            ]
        }.value
        var next: [String: ProviderSnapshot] = [:]
        for fresh in fetched {
            if allowNetwork {
                next[fresh.providerID] = fresh
            } else {
                next[fresh.providerID] = Self.retainQuietTick(fresh, previous: previous[fresh.providerID])
            }
        }
        let input = ToolDetector.probe(
            home: home,
            applicationDirectories: [
                URL(fileURLWithPath: "/Applications"),
                home.appendingPathComponent("Applications"),
                URL(fileURLWithPath: "/System/Applications"),
            ],
            path: environment["PATH"] ?? "",
            environment: environment
        )
        catalog = ToolDetector.status(for: input)
        if !providerChoices.contains(where: { $0.id == selectedProviderID }) {
            selectedProviderID = ToolCatalog.claudeCode
        }
        apply(next)
    }

    /// Quiet ticks keep the last networked usage windows. A local pass still
    /// refreshes sessions, and it cannot drop a row the fallback source lacks.
    private static func retainQuietTick(_ fresh: ProviderSnapshot, previous: ProviderSnapshot?) -> ProviderSnapshot {
        guard let previous else { return fresh }
        var merged = fresh
        if !previous.windows.isEmpty {
            merged.windows = previous.windows
            merged.notice = previous.notice
            merged.retryAfter = previous.retryAfter
        } else if fresh.notice == nil, let notice = previous.notice {
            merged.notice = notice
            merged.retryAfter = previous.retryAfter
        }
        if previous.today.origin == .server {
            merged.today = previous.today
        }
        return merged
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

    private func apply(_ next: [String: ProviderSnapshot]) {
        let previous = Set(snapshot.sessions.filter { $0.activity == .needsYou }.map(\.id))
        snapshots = next
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
