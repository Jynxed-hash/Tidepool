#if os(macOS)
import AppKit
import Darwin
import ProviderKit
import QuartzCore
import ScreenCaptureKit
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
            notice: "Sign in with Claude Code, then reopen Tidepool.",
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
            notice: "Grok Bot doesn't share usage data yet.",
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
}

/// One on-screen panel. `screencapture -l` and `CGWindowListCreateImage` see the
/// composited window, including AppKit controls and the material.
@MainActor
private final class PanelCaptureWindow {
    struct Report {
        var yellowPixels: Int
        var inkHeight: CGFloat
        var middleInk: CGFloat
        var variance: Double
        var cornerLuminance: Double
        var method: String
        var pixelSize: CGSize
    }

    private let window: NSWindow
    private let effect: NSVisualEffectView
    private let host: NSHostingView<AnyView>
    private let size = NSSize(width: PanelChrome.width, height: PanelChrome.height)

    init() {
        let app = NSApplication.shared
        if app.activationPolicy() == .prohibited {
            app.setActivationPolicy(.accessory)
        }
        app.activate()
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.sharingType = .readOnly
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .menu
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        host = NSHostingView(rootView: AnyView(Color.clear))
        host.safeAreaRegions = []
        host.sizingOptions = []
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.isOpaque = false
        effect.addSubview(host)
        window.contentView = effect
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            ))
        }
    }

    func show(store: TidepoolStore, scheme: ColorScheme) {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.appearance = appearance
        effect.appearance = appearance
        host.appearance = appearance
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            host.rootView = AnyView(
                PanelView()
                    .environment(store)
                    .environment(\.colorScheme, scheme)
            )
        }
        window.setContentSize(size)
        host.frame = effect.bounds
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    func capture() async -> (Data, String)? {
        window.setContentSize(size)
        host.frame = effect.bounds
        pump(0.45)
        let id = CGWindowID(window.windowNumber)
        guard id != 0 else { return nil }
        var best: (Data, String, Report)?
        for _ in 0..<4 {
            var shots: [(Data, String)] = []
            if let data = screenshot(windowID: id) {
                shots.append((data, "screencapture"))
            }
            if let data = windowImage(windowID: id) {
                shots.append((data, "CGWindowListCreateImage"))
            }
            if let data = await screenshotKit(windowID: id) {
                shots.append((data, "ScreenCaptureKit"))
            }
            for shot in shots {
                guard let report = Self.inspect(shot.0, method: shot.1) else { continue }
                if best == nil || report.inkHeight > best!.2.inkHeight {
                    best = (shot.0, shot.1, report)
                }
                if report.yellowPixels < 24, report.inkHeight > 80, report.variance > 0.002 {
                    return (shot.0, shot.1)
                }
            }
            pump(0.25)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        if let best { return (best.0, best.1) }
        return nil
    }

    func close() {
        window.orderOut(nil)
    }

    static func inspect(_ data: Data, method: String) -> Report? {
        guard let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 8, rep.pixelsHigh > 8 else { return nil }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        let scale = Double(width) / Double(PanelChrome.width)
        let aspect = Double(width) / Double(height)
        let expectedAspect = Double(PanelChrome.width / PanelChrome.height)
        guard scale > 0.5, abs(aspect - expectedAspect) < 0.08 else { return nil }
        var yellow = 0
        var inkRows = 0
        var middleRows = 0
        var sum = 0.0
        var sumSquares = 0.0
        var samples = 0.0
        let middleStart = Int(Double(height) * 0.22)
        let middleEnd = Int(Double(height) * 0.78)
        let stepX = max(1, width / 160)
        for y in 0..<height {
            var lowest = 1.0
            var highest = 0.0
            var x = 0
            while x < width {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    x += stepX
                    continue
                }
                let red = color.redComponent
                let green = color.greenComponent
                let blue = color.blueComponent
                if red > 0.93, green > 0.70, green < 0.90, blue < 0.20, red - blue > 0.7 {
                    yellow += 1
                }
                let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                lowest = min(lowest, luminance)
                highest = max(highest, luminance)
                if y % 4 == 0, x % (stepX * 2) == 0 {
                    sum += luminance
                    sumSquares += luminance * luminance
                    samples += 1
                }
                x += stepX
            }
            if highest - lowest > 0.12 {
                inkRows += 1
                if y >= middleStart, y < middleEnd {
                    middleRows += 1
                }
            }
        }
        guard samples > 0 else { return nil }
        let mean = sum / samples
        let corner = cornerLuminance(rep)
        return Report(
            yellowPixels: yellow,
            inkHeight: CGFloat(Double(inkRows) / scale),
            middleInk: CGFloat(Double(middleRows) / scale),
            variance: sumSquares / samples - mean * mean,
            cornerLuminance: corner,
            method: method,
            pixelSize: CGSize(width: width, height: height)
        )
    }

    static func contactSheet(entries: [(name: String, light: Data, dark: Data)]) -> Data? {
        let cell = NSSize(width: 240, height: 390)
        let labelWidth: CGFloat = 132
        let gap: CGFloat = 8
        let rowHeight = cell.height + 28
        let width = labelWidth + gap + cell.width * 2 + gap
        let height = rowHeight * CGFloat(entries.count) + gap
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { bounds in
            NSColor.black.setFill()
            bounds.fill()
            for (index, entry) in entries.enumerated() {
                let y = gap + CGFloat(index) * rowHeight
                let title = NSAttributedString(
                    string: entry.name,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                        .foregroundColor: NSColor.white,
                    ]
                )
                title.draw(in: NSRect(x: 8, y: y + 4, width: labelWidth - 12, height: 20))
                draw(entry.light, in: NSRect(x: labelWidth, y: y + 24, width: cell.width, height: cell.height))
                draw(entry.dark, in: NSRect(x: labelWidth + cell.width + gap, y: y + 24, width: cell.width, height: cell.height))
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func screenshot(windowID: CGWindowID) -> Data? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tidepool-window-\(windowID)-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-l\(windowID)", "-o", "-x", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            print("screencapture failed to launch: \(error)")
            return nil
        }
        let deadline = Date().addingTimeInterval(6)
        while process.isRunning, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            process.terminate()
        }
        let log = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: url),
              data.count > 800 else {
            print("screencapture \(windowID) status \(process.terminationStatus) \(log)")
            return nil
        }
        return data
    }

    /// The macOS 26 SDK marks `CGWindowListCreateImage` unavailable and points at
    /// ScreenCaptureKit. The symbol is still how a test captures one window,
    /// including its material, so the call goes through the framework directly.
    private func windowImage(windowID: CGWindowID) -> Data? {
        guard let symbol = dlsym(
            dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
            "CGWindowListCreateImage"
        ) else { return nil }
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3
        let ignoreFrameAndBestResolution: UInt32 = (1 << 0) | (1 << 3)
        guard let image = create(.null, includingWindow, windowID, ignoreFrameAndBestResolution)?.takeRetainedValue() else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    private nonisolated func screenshotKit(windowID: CGWindowID) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask { await Self.captureKit(windowID) }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private nonisolated static func captureKit(_ windowID: CGWindowID) async -> Data? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                print("ScreenCaptureKit did not list window \(windowID)")
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = Int(PanelChrome.width * 2)
            config.height = Int(PanelChrome.height * 2)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            return rep.representation(using: .png, properties: [:])
        } catch {
            print("ScreenCaptureKit capture failed: \(error)")
            return nil
        }
    }

    private func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private static func cornerLuminance(_ rep: NSBitmapImageRep) -> Double {
        let limit = min(48, min(rep.pixelsWide, rep.pixelsHigh))
        var inset = 2
        while inset < limit {
            if let color = rep.colorAt(x: inset, y: inset)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 {
                return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
            }
            inset += 2
        }
        return 0
    }

    private static func draw(_ data: Data, in rect: NSRect) {
        guard let image = NSImage(data: data) else { return }
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
    }
}

@Test @MainActor func comingSoonToolsStayInTheProviderMenu() {
    let store = PanelFixtures.store(selected: ToolCatalog.wisprFlow, snapshots: [:])
    #expect(store.providerChoices.contains { $0.id == ToolCatalog.wisprFlow })
    #expect(store.selectedTitle == "Wispr Flow")
    #expect(store.selectedIsComingSoon)
}

@Test func panelTextClearsContrast() {
    #expect(PanelChrome.width == 320)
    #expect(PanelChrome.height == 520)
    #expect(PanelChrome.margin == 16)
    #expect(PanelChrome.grid == 8)
    #expect(PanelChrome.control == 28)
    #expect(PanelInk.contrast(PanelInk.lightSecondary, on: PanelInk.lightCanvas) >= 4.5)
    #expect(PanelInk.contrast(PanelInk.darkSecondary, on: PanelInk.darkCanvas) >= 4.5)
    #expect(PanelInk.contrast((0, 0, 0), on: PanelInk.lightCanvas) >= 4.5)
    #expect(PanelInk.contrast((1, 1, 1), on: PanelInk.darkCanvas) >= 4.5)
    #expect(PanelInk.contrast(PanelInk.lightNeedsYou, on: PanelInk.lightCanvas) >= 4.5)
    #expect(PanelInk.contrast(PanelInk.darkNeedsYou, on: PanelInk.darkCanvas) >= 4.5)
    #expect(PanelInk.contrast(PanelInk.lightLimit, on: PanelInk.lightCanvas) >= 4.5)
    #expect(PanelInk.contrast(PanelInk.darkLimit, on: PanelInk.darkCanvas) >= 4.5)
}

@Test @MainActor func panelWindowSizeStaysFixedAcrossProviders() async throws {
    var locked: [CGSize] = []
    var naturalHeights: [String: CGFloat] = [:]
    var lines: [String] = []

    for fixture in PanelFixtures.cases {
        let natural = PanelMeasurer.fittingSize(
            of: PanelView(locksWindowSize: false).environment(fixture.store)
        )
        naturalHeights[fixture.name] = natural.height
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
        print("screenCaptureAccess=\(CGPreflightScreenCaptureAccess()) screens=\(NSScreen.screens.count)")
        let capture = PanelCaptureWindow()
        defer { capture.close() }
        var sheet: [(name: String, light: Data, dark: Data)] = []
        for fixture in PanelFixtures.cases {
            var pair: [String: Data] = [:]
            let natural = naturalHeights[fixture.name] ?? PanelChrome.height
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                let schemeName = scheme == .dark ? "dark" : "light"
                capture.show(store: fixture.store, scheme: scheme)
                let shot = try #require(await capture.capture(), "Live window capture failed for \(fixture.name) \(schemeName)")
                let data = shot.0
                let stats = try #require(PanelCaptureWindow.inspect(data, method: shot.1))
                let url = folder.appendingPathComponent("\(fixture.name)-\(schemeName).png")
                try data.write(to: url)
                pair[schemeName] = data
                let expected = min(natural, PanelChrome.height)
                lines.append(
                    "\(fixture.name) \(schemeName) method=\(stats.method) pixels=\(Int(stats.pixelSize.width))x\(Int(stats.pixelSize.height)) yellow=\(stats.yellowPixels) ink=\(stats.inkHeight) middle=\(stats.middleInk) variance=\(stats.variance) corner=\(stats.cornerLuminance) expected=\(expected)"
                )
                #expect(stats.yellowPixels < 24, "\(fixture.name) \(schemeName) has placeholder-yellow pixels (\(stats.yellowPixels))")
                #expect(stats.variance > 0.002, "\(fixture.name) \(schemeName) capture is flat")
                // Meter tracks are low contrast, so ink rows run shorter than the natural stack.
                // A header-only capture is still well under this line.
                #expect(stats.inkHeight >= expected * 0.30, "\(fixture.name) \(schemeName) drawn ink \(stats.inkHeight) is far below \(expected)")
                #expect(stats.middleInk >= 24, "\(fixture.name) \(schemeName) has almost no ink below the header")
                if scheme == .dark {
                    #expect(stats.cornerLuminance > 0.02, "\(fixture.name) dark capture is black, so the material did not composite")
                    #expect(stats.cornerLuminance < 0.55, "\(fixture.name) dark capture is light")
                } else {
                    #expect(stats.cornerLuminance > 0.45, "\(fixture.name) light capture is dark")
                }
            }
            if let light = pair["light"], let dark = pair["dark"] {
                sheet.append((name: fixture.name, light: light, dark: dark))
            }
        }
        if let contact = PanelCaptureWindow.contactSheet(entries: sheet) {
            try contact.write(to: folder.appendingPathComponent("contact-sheet.png"))
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
    let heights = Array(naturalHeights.values)
    let spread = (heights.max() ?? 0) - (heights.min() ?? 0)
    #expect(spread > 40)
    let claude = try #require(naturalHeights["claude-ready"])
    #expect(claude <= PanelChrome.height + 0.5)
}
#endif
