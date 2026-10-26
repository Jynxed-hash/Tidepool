#if os(macOS)
import AppKit
import ProviderKit
import SwiftUI
import Testing
@testable import Tidepool

@MainActor
private enum PanelFixtures {
    /// Captured when the fixtures are built so the 5-hour countdown is a couple of hours, not a year-old "Reset due".
    static let now = Date()

    static let catalog: [CatalogStatus] = [
        CatalogStatus(id: ToolCatalog.claudeCode, displayName: "Claude Code", state: .active, evidence: [".claude"]),
        CatalogStatus(id: ToolCatalog.geminiCLI, displayName: "Gemini CLI", state: .active, evidence: [".gemini"]),
        CatalogStatus(id: ToolCatalog.wisprFlow, displayName: "Wispr Flow", state: .comingSoon, evidence: ["Wispr Flow.app"]),
        CatalogStatus(id: ToolCatalog.grokBot, displayName: "Grok Bot", state: .limitedData, evidence: ["Grok Bot.app"]),
        CatalogStatus(
            id: ToolCatalog.copilot,
            displayName: "GitHub Copilot",
            state: .active,
            evidence: [".config/github-copilot"],
            unofficial: true
        ),
        CatalogStatus(id: ToolCatalog.windsurf, displayName: "Devin Desktop", state: .comingSoon, evidence: ["Devin.app"]),
    ]

    static func store(
        selected: String,
        snapshots: [String: ProviderSnapshot],
        showingSettings: Bool = false,
        menuFormat: MenuBarFormat = .symbolPercent
    ) -> TidepoolStore {
        let name = "tidepool-panel-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let store = TidepoolStore(defaults: defaults, startsRefresh: false)
        store.catalog = catalog
        store.selectedProviderID = selected
        store.replaceSnapshots(snapshots)
        store.showingSettings = showingSettings
        store.menuFormat = menuFormat
        return store
    }

    static var cases: [(name: String, store: TidepoolStore)] {
        [
            (
                "claude-ready",
                store(
                    selected: ToolCatalog.claudeCode,
                    snapshots: [ToolCatalog.claudeCode: claudeReady],
                    menuFormat: .symbolPercentReset
                )
            ),
            ("claude-sign-in", store(selected: ToolCatalog.claudeCode, snapshots: [ToolCatalog.claudeCode: claudeSignIn])),
            ("gemini-ready", store(selected: ToolCatalog.geminiCLI, snapshots: [ToolCatalog.geminiCLI: geminiReady])),
            ("gemini-sign-in", store(selected: ToolCatalog.geminiCLI, snapshots: [ToolCatalog.geminiCLI: geminiSignIn])),
            ("wispr-coming-soon", store(selected: ToolCatalog.wisprFlow, snapshots: [:])),
            ("grok-limited", store(selected: ToolCatalog.grokBot, snapshots: [ToolCatalog.grokBot: grokLimited])),
            ("copilot-unofficial", store(selected: ToolCatalog.copilot, snapshots: [ToolCatalog.copilot: copilotReady])),
            ("settings", store(selected: ToolCatalog.claudeCode, snapshots: [ToolCatalog.claudeCode: claudeReady], showingSettings: true)),
        ]
    }

    private static var claudeReady: ProviderSnapshot {
        ProviderSnapshot(
            providerID: ToolCatalog.claudeCode,
            windows: [
                window("five_hour", "5-hour session", 42, hours: 2, countdown: true),
                window("seven_day", "Weekly · all models", 61, hours: 72, countdown: false),
                window("seven_day_opus", "Weekly · Opus", 18, hours: 72, countdown: false),
            ],
            sessions: [
                TrackedSession(
                    id: "needs",
                    repo: "acme-web",
                    branch: "feat/checkout",
                    cwd: "/tmp/acme-web",
                    activity: .needsYou,
                    toolName: "Bash",
                    waitingDetail: "npm test",
                    updatedAt: now,
                    origin: .hook
                ),
                TrackedSession(
                    id: "working",
                    repo: "tidepool",
                    branch: "main",
                    cwd: "/tmp/tidepool",
                    activity: .working,
                    updatedAt: now,
                    origin: .hook
                ),
                TrackedSession(
                    id: "idle",
                    repo: "notes",
                    branch: "main",
                    activity: .idle,
                    idleSince: now.addingTimeInterval(-3600),
                    updatedAt: now,
                    origin: .estimate
                ),
            ],
            today: UsageEstimate(tokens: 128_400, costUSD: 1.25, origin: .estimate),
            checkedAt: now
        )
    }

    private static var claudeSignIn: ProviderSnapshot {
        ProviderSnapshot(
            providerID: ToolCatalog.claudeCode,
            notice: "Sign in with Claude Code, then open Tidepool again. If you are already signed in, allow the keychain prompt for Claude Code-credentials.",
            checkedAt: now
        )
    }

    private static var geminiReady: ProviderSnapshot {
        ProviderSnapshot(
            providerID: ToolCatalog.geminiCLI,
            windows: [
                window("gemini-2-5-pro", "gemini-2.5-pro", 37, hours: 5, countdown: true),
                window("gemini-2-5-flash", "gemini-2.5-flash", 12, hours: 5, countdown: true),
            ],
            checkedAt: now
        )
    }

    private static var geminiSignIn: ProviderSnapshot {
        ProviderSnapshot(
            providerID: ToolCatalog.geminiCLI,
            notice: "Gemini CLI quota needs ~/.gemini/oauth_creds.json. Tidepool does not refresh the token.",
            checkedAt: now
        )
    }

    private static var grokLimited: ProviderSnapshot {
        ProviderSnapshot(
            providerID: ToolCatalog.grokBot,
            notice: "Grok Bot doesn't publish a usage figure this app can read. The weekly pool is in Grok Bot under Settings → Usage & Billing, and at grok.com/dashboard. Approval prompts stay in the Grok Bot conversation.",
            checkedAt: now,
            availability: .limited
        )
    }

    private static var copilotReady: ProviderSnapshot {
        ProviderSnapshot(
            providerID: ToolCatalog.copilot,
            windows: [
                window("premium", "Premium", 20, hours: 240, countdown: false),
                window("chat", "Chat", 90, hours: 240, countdown: false),
                window("completions", "Completions", 4, hours: 240, countdown: false),
            ],
            checkedAt: now
        )
    }

    private static func window(
        _ id: String,
        _ title: String,
        _ used: Double,
        hours: TimeInterval,
        countdown: Bool
    ) -> UsageWindow {
        UsageWindow(
            id: id,
            title: title,
            usedPercent: used,
            resetsAt: now.addingTimeInterval(hours * 3600),
            origin: .server,
            showsCountdown: countdown
        )
    }
}

@MainActor
private enum PanelMeasurer {
    static func fittingSize<V: View>(of view: V) -> CGSize {
        let controller = NSHostingController(rootView: view)
        controller.safeAreaRegions = []
        return controller.sizeThatFits(in: CGSize(width: PanelChrome.width, height: 4_000))
    }

    static func png<V: View>(of view: V, size: CGSize) -> Data? {
        let rendered = ImageRenderer(content: view)
        rendered.scale = 2
        rendered.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        rendered.isOpaque = false
        if let image = rendered.nsImage, let data = pngData(image), !data.isEmpty {
            return data
        }
        return rasterized(view, size: size)
    }

    private static func rasterized<V: View>(_ view: V, size: CGSize) -> Data? {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

@Test @MainActor func comingSoonToolsStayInTheProviderMenu() {
    let store = PanelFixtures.store(selected: ToolCatalog.wisprFlow, snapshots: [:])
    #expect(store.providerChoices.contains { $0.id == ToolCatalog.wisprFlow })
    #expect(store.selectedTitle == "Wispr Flow")
    #expect(store.selectedIsComingSoon)
}

@Test @MainActor func panelWindowSizeStaysFixedAcrossProviders() throws {
    var locked: [CGSize] = []
    var naturalHeights: [CGFloat] = []
    var lines: [String] = []

    for fixture in PanelFixtures.cases {
        let natural = PanelMeasurer.fittingSize(
            of: PanelView(locksWindowSize: false).environment(fixture.store)
        )
        naturalHeights.append(natural.height)
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let view = PanelView()
                .environment(fixture.store)
                .environment(\.colorScheme, scheme)
            let size = PanelMeasurer.fittingSize(of: view)
            locked.append(size)
            let schemeName = scheme == .dark ? "dark" : "light"
            lines.append("\(fixture.name) \(schemeName) window=\(size.width)x\(size.height) natural=\(natural.width)x\(natural.height)")
        }
    }

    if let directory = ProcessInfo.processInfo.environment["TIDEPOOL_PANEL_SNAPSHOTS"], !directory.isEmpty {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for fixture in PanelFixtures.cases {
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                let schemeName = scheme == .dark ? "dark" : "light"
                let view = PanelView()
                    .environment(fixture.store)
                    .environment(\.colorScheme, scheme)
                let data = try #require(
                    PanelMeasurer.png(
                        of: view,
                        size: CGSize(width: PanelChrome.width, height: PanelChrome.height)
                    )
                )
                let url = folder.appendingPathComponent("\(fixture.name)-\(schemeName).png")
                try data.write(to: url)
            }
        }
        let report = lines.joined(separator: "\n") + "\n"
        try report.write(to: folder.appendingPathComponent("sizes.txt"), atomically: true, encoding: .utf8)
    }

    let first = try #require(locked.first)
    #expect(abs(first.width - PanelChrome.width) < 0.5)
    #expect(abs(first.height - PanelChrome.height) < 0.5)
    for size in locked {
        #expect(abs(size.width - first.width) < 0.5)
        #expect(abs(size.height - first.height) < 0.5)
    }
    let spread = (naturalHeights.max() ?? 0) - (naturalHeights.min() ?? 0)
    #expect(spread > 40)
}
#endif
