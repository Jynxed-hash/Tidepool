import AppKit
import ProviderKit
import SwiftUI

/// Menu-bar window. Width stays 320. Height stays 520 so a Claude page with
/// meters, sessions, and the reset line does not scroll. Settings may.
enum PanelChrome {
    static let width: CGFloat = 320
    static let height: CGFloat = 520
    static let margin: CGFloat = 16
    static let grid: CGFloat = 8
    static let control: CGFloat = 28
    static let crossfade: TimeInterval = 0.18
}

/// Text colors chosen to clear 4.5:1 on the window canvas. System `.secondary`
/// is about 3.5:1 on white, so section headers and supporting copy use these.
enum PanelInk {
    static func canvas(_ scheme: ColorScheme) -> Color {
        color(scheme == .dark ? darkCanvas : lightCanvas)
    }

    static func raised(_ scheme: ColorScheme) -> Color {
        color(scheme == .dark ? darkRaised : lightRaised)
    }

    static func separator(_ scheme: ColorScheme) -> Color {
        color(scheme == .dark ? darkSeparator : lightSeparator)
    }

    static func primary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white : Color.black
    }

    static func secondary(_ scheme: ColorScheme) -> Color {
        color(scheme == .dark ? darkSecondary : lightSecondary)
    }

    static func needsYou(_ scheme: ColorScheme) -> Color {
        color(scheme == .dark ? darkNeedsYou : lightNeedsYou)
    }

    static func limit(_ scheme: ColorScheme) -> Color {
        color(scheme == .dark ? darkLimit : lightLimit)
    }

    static let lightCanvas = (1.0, 1.0, 1.0)
    static let darkCanvas = (44.0 / 255, 44.0 / 255, 46.0 / 255)
    static let lightRaised = (242.0 / 255, 242.0 / 255, 244.0 / 255)
    static let darkRaised = (58.0 / 255, 58.0 / 255, 60.0 / 255)
    static let lightSeparator = (198.0 / 255, 198.0 / 255, 200.0 / 255)
    static let darkSeparator = (84.0 / 255, 84.0 / 255, 88.0 / 255)
    static let lightSecondary = (0.29, 0.29, 0.29)
    static let darkSecondary = (0.92, 0.92, 0.92)
    static let lightNeedsYou = (154.0 / 255, 52.0 / 255, 18.0 / 255)
    static let darkNeedsYou = (255.0 / 255, 159.0 / 255, 10.0 / 255)
    static let lightLimit = (215.0 / 255, 0.0, 21.0 / 255)
    static let darkLimit = (255.0 / 255, 105.0 / 255, 97.0 / 255)

    static func contrast(
        _ foreground: (Double, Double, Double),
        on background: (Double, Double, Double)
    ) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        func luminance(_ sample: (Double, Double, Double)) -> Double {
            0.2126 * linear(sample.0) + 0.7152 * linear(sample.1) + 0.0722 * linear(sample.2)
        }
        let lighter = max(luminance(foreground), luminance(background))
        let darker = min(luminance(foreground), luminance(background))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func color(_ sample: (Double, Double, Double)) -> Color {
        Color(.sRGB, red: sample.0, green: sample.1, blue: sample.2, opacity: 1)
    }
}

struct PanelView: View {
    /// Layout tests measure the natural stack with this set to false.
    var locksWindowSize = true

    @Environment(TidepoolStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var glass
    @State private var contentScrolled = false

    var body: some View {
        if locksWindowSize {
            ZStack(alignment: .top) {
                locked
                    .id(pageID)
                    .transition(.opacity)
            }
            .animation(crossfade, value: pageID)
            .frame(
                minWidth: PanelChrome.width,
                idealWidth: PanelChrome.width,
                maxWidth: PanelChrome.width,
                minHeight: PanelChrome.height,
                idealHeight: PanelChrome.height,
                maxHeight: PanelChrome.height,
                alignment: .top
            )
            .background(Color.clear)
            .onChange(of: pageID) { _, _ in contentScrolled = false }
        } else {
            intrinsic
                .frame(width: PanelChrome.width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pageID: String {
        store.showingSettings ? "settings" : store.selectedProviderID
    }

    /// Opacity only. `.smooth` would also move the frame.
    private var crossfade: Animation? {
        reduceMotion ? nil : .easeInOut(duration: PanelChrome.crossfade)
    }

    private var locked: some View {
        VStack(spacing: 0) {
            headerBar
            headerSeparator
            if store.showingSettings {
                ScrollView(.vertical) {
                    SettingsView()
                }
                .scrollIndicators(.automatic)
                .scrollBounceBehavior(.basedOnSize)
                .scrollContentBackground(.hidden)
                .trackScrollUnderHeader($contentScrolled)
            } else if let quiet {
                quietMessage(quiet)
                    .padding(.horizontal, PanelChrome.margin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
                    .padding(.horizontal, PanelChrome.margin)
                    .padding(.bottom, PanelChrome.margin)
            } else {
                ScrollView(.vertical) {
                    dataColumn
                        .padding(.horizontal, PanelChrome.margin)
                        .padding(.bottom, PanelChrome.margin)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(.automatic)
                .scrollBounceBehavior(.basedOnSize)
                .scrollContentBackground(.hidden)
                .trackScrollUnderHeader($contentScrolled)
            }
        }
    }

    /// Uncentered stack. Its height is what the window would hug.
    private var intrinsic: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            if store.showingSettings {
                SettingsView()
            } else if let quiet {
                quietMessage(quiet)
                    .padding(.horizontal, PanelChrome.margin)
                    .padding(.top, PanelChrome.grid)
                footer
                    .padding(.horizontal, PanelChrome.margin)
                    .padding(.top, PanelChrome.grid)
                    .padding(.bottom, PanelChrome.margin)
            } else {
                dataColumn
                    .padding(.horizontal, PanelChrome.margin)
                    .padding(.bottom, PanelChrome.margin)
            }
        }
    }

    private var headerSeparator: some View {
        PanelInk.separator(colorScheme)
            .frame(height: contentScrolled ? 1 : 0)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var headerBar: some View {
        if store.showingSettings {
            HStack(spacing: PanelChrome.grid) {
                Button {
                    store.showingSettings = false
                } label: {
                    Image(systemName: "chevron.backward")
                        .frame(minWidth: PanelChrome.control, minHeight: PanelChrome.control)
                }
                .panelIconButton()
                .accessibilityLabel("Back")
                Text("Settings")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PanelInk.primary(colorScheme))
                Spacer(minLength: PanelChrome.grid)
            }
            .padding(.horizontal, PanelChrome.margin)
            .padding(.top, PanelChrome.margin)
            .padding(.bottom, PanelChrome.grid)
        } else {
            header
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PanelChrome.grid) {
            HStack(spacing: PanelChrome.grid) {
                providerTitle
                if store.selectedIsUnofficial {
                    unofficialBadge
                }
                Spacer(minLength: PanelChrome.grid)
                Button {
                    Task { await store.setNotifications(enabled: !store.notificationsEnabled) }
                } label: {
                    Image(systemName: store.notificationsEnabled ? "bell" : "bell.slash")
                        .frame(minWidth: PanelChrome.control, minHeight: PanelChrome.control)
                }
                .panelIconButton()
                .accessibilityLabel(store.notificationsEnabled ? "Notifications on" : "Notifications off")
            }
            if let reset = store.panelReset {
                Text(reset)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(PanelInk.secondary(colorScheme))
            }
        }
        .padding(.horizontal, PanelChrome.margin)
        .padding(.top, PanelChrome.margin)
        .padding(.bottom, PanelChrome.grid)
    }

    private var unofficialBadge: some View {
        Text("Unofficial")
            .font(.caption2)
            .foregroundStyle(PanelInk.secondary(colorScheme))
            .padding(.horizontal, PanelChrome.grid)
            .padding(.vertical, 3)
            .overlay {
                Capsule().strokeBorder(PanelInk.separator(colorScheme), lineWidth: 1)
            }
            .accessibilityLabel("Unofficial")
    }

    @ViewBuilder
    private var providerTitle: some View {
        if store.providerChoices.count > 1 {
            Menu {
                ForEach(store.providerChoices) { tool in
                    Button(tool.displayName) { store.selectProvider(tool.id) }
                }
            } label: {
                HStack(spacing: PanelChrome.grid) {
                    Text(store.selectedTitle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(PanelInk.primary(colorScheme))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(PanelInk.secondary(colorScheme))
                }
                .frame(minHeight: PanelChrome.control)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Provider, \(store.selectedTitle)")
        } else {
            Text(store.selectedTitle)
                .font(.body.weight(.semibold))
                .foregroundStyle(PanelInk.primary(colorScheme))
                .frame(minHeight: PanelChrome.control)
        }
    }

    private struct QuietPage {
        var symbol: String
        var title: String
        var message: String
        var linkTitle: String?
        var linkURL: URL?
    }

    private var quiet: QuietPage? {
        if store.selectedIsComingSoon {
            return QuietPage(
                symbol: "hourglass",
                title: "Coming soon",
                message: "\(store.selectedTitle) is on this Mac. Tidepool does not read it yet."
            )
        }
        if store.snapshot.availability == .limited {
            if store.snapshot.providerID == ToolCatalog.grokBot {
                return QuietPage(
                    symbol: "chart.bar.xaxis",
                    title: "Limited data",
                    message: "Grok Bot doesn't share usage data yet.",
                    linkTitle: "Open dashboard",
                    linkURL: URL(string: "https://grok.com/dashboard")
                )
            }
            return QuietPage(
                symbol: "chart.bar.xaxis",
                title: "Limited data",
                message: store.snapshot.notice ?? "Tidepool can't read a usage figure for \(store.selectedTitle)."
            )
        }
        let empty = store.snapshot.windows.isEmpty && store.snapshot.sessions.isEmpty
        if empty {
            return QuietPage(
                symbol: "person.crop.circle",
                title: "Sign in",
                message: signInMessage
            )
        }
        return nil
    }

    /// Keychain copy is only for a read that was denied. A missing login stays one short sentence.
    private var signInMessage: String {
        let notice = store.snapshot.notice ?? store.actionNotice
        if store.snapshot.providerID == ToolCatalog.claudeCode {
            if notice?.localizedCaseInsensitiveContains("keychain") == true {
                return "Allow the keychain prompt for Claude Code-credentials."
            }
            if notice == nil || notice?.hasPrefix("Sign in") == true {
                return "Sign in with Claude Code, then reopen Tidepool."
            }
        }
        return notice ?? "Sign in to \(store.selectedTitle), then open Tidepool again."
    }

    private func quietMessage(_ quiet: QuietPage) -> some View {
        VStack(spacing: PanelChrome.grid) {
            Image(systemName: quiet.symbol)
                .font(.system(size: 32))
                .foregroundStyle(PanelInk.secondary(colorScheme))
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            Text(quiet.title)
                .font(.headline)
                .foregroundStyle(PanelInk.primary(colorScheme))
                .multilineTextAlignment(.center)
            Text(quiet.message)
                .font(.callout)
                .foregroundStyle(PanelInk.secondary(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 260)
            if let title = quiet.linkTitle, let url = quiet.linkURL {
                Button(title) {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.link)
                .font(.callout)
                .frame(minHeight: PanelChrome.control)
                .accessibilityLabel(title)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var dataColumn: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            panelGlass {
                VStack(alignment: .leading, spacing: PanelChrome.grid) {
                    if store.snapshot.availability != .limited,
                       let attention = store.snapshot.sessions.first(where: { $0.activity == .needsYou }) {
                        attentionPill(attention)
                    }
                    if let notice = store.snapshot.notice ?? store.actionNotice {
                        Text(notice)
                            .font(.body)
                            .foregroundStyle(PanelInk.secondary(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if store.snapshot.availability != .limited {
                        usage(now: timeline.date)
                        if showsSessions {
                            sessions(now: timeline.date)
                        }
                    }
                    footer
                }
            }
        }
    }

    private func attentionPill(_ session: TrackedSession) -> some View {
        Button {
            store.focusNeedsYou()
        } label: {
            HStack(spacing: PanelChrome.grid) {
                StatusDot(activity: .needsYou)
                Text(session.repo)
                    .foregroundStyle(PanelInk.primary(colorScheme))
                if let branch = session.branch {
                    BranchLabel(branch)
                }
                Spacer(minLength: PanelChrome.grid)
                Text("Needs you")
                    .foregroundStyle(PanelInk.needsYou(colorScheme))
            }
            .font(.body)
            .padding(.horizontal, PanelChrome.grid)
            .frame(minHeight: PanelChrome.control)
        }
        .buttonStyle(.plain)
        .tidepoolGlass(id: "pill-\(session.id)", namespace: glass, shape: Capsule())
    }

    private func usage(now: Date) -> some View {
        VStack(alignment: .leading, spacing: PanelChrome.grid) {
            if store.snapshot.windows.isEmpty {
                if store.snapshot.providerID == ToolCatalog.claudeCode {
                    Text("Usage appears after Claude Code is signed in.")
                        .font(.body)
                        .foregroundStyle(PanelInk.secondary(colorScheme))
                }
            } else {
                ForEach(store.snapshot.windows) { window in
                    UsageRow(window: window, now: now)
                }
            }
        }
    }

    /// API meters have no session feed. An empty list would look like a failed lookup.
    private var showsSessions: Bool {
        if !store.snapshot.sessions.isEmpty { return true }
        switch store.snapshot.providerID {
        case ToolCatalog.openRouter, ToolCatalog.geminiCLI, ToolCatalog.openCode, ToolCatalog.zai, ToolCatalog.deepSeek,
            ToolCatalog.cursor, ToolCatalog.copilot:
            return false
        default:
            return true
        }
    }

    private func sessions(now: Date) -> some View {
        VStack(alignment: .leading, spacing: PanelChrome.grid) {
            HStack {
                sectionHeader("Sessions")
                Spacer()
                Text(sessionCount)
                    .font(.caption)
                    .foregroundStyle(PanelInk.secondary(colorScheme))
                    .monospacedDigit()
            }
            if store.snapshot.sessions.isEmpty {
                Text("No sessions right now.")
                    .font(.caption)
                    .foregroundStyle(PanelInk.secondary(colorScheme))
            } else {
                ForEach(store.snapshot.sessions.prefix(6)) { session in
                    SessionRow(
                        session: session,
                        expanded: store.expandedSessionID == session.id,
                        now: now,
                        namespace: glass,
                        cursorInstalled: store.catalog.contains { $0.id == ToolCatalog.cursor && $0.state != .notDetected && $0.state != .undetectable }
                    )
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PanelInk.secondary(colorScheme))
    }

    private var sessionCount: String {
        let count = store.snapshot.sessions.count
        return count == 1 ? "1 active" : "\(count) active"
    }

    private var showsToday: Bool {
        if store.snapshot.availability == .limited { return false }
        if store.selectedIsComingSoon { return false }
        if store.snapshot.windows.isEmpty && store.snapshot.sessions.isEmpty { return false }
        if store.snapshot.providerID == ToolCatalog.claudeCode { return true }
        return store.snapshot.today.tokens > 0 || store.snapshot.today.costUSD != nil
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: PanelChrome.grid) {
            if showsToday {
                Text(TokenFormat.todayLine(store.snapshot.today))
                    .font(.caption)
                    .foregroundStyle(PanelInk.secondary(colorScheme))
                    .monospacedDigit()
            }
            Spacer(minLength: PanelChrome.grid)
            Button {
                store.showingSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
                    .frame(minWidth: PanelChrome.control, minHeight: PanelChrome.control)
            }
            .panelIconButton()
            .accessibilityLabel("Settings")
        }
    }

    private func panelGlass<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        GlassEffectContainer(spacing: PanelChrome.grid) {
            content()
        }
    }
}

private extension View {
    func trackScrollUnderHeader(_ scrolled: Binding<Bool>) -> some View {
        onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y > 1
        } action: { _, under in
            scrolled.wrappedValue = under
        }
    }
}

struct UsageRow: View {
    var window: UsageWindow
    var now: Date
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title)
                    .font(.body)
                    .foregroundStyle(PanelInk.primary(colorScheme))
                Spacer()
                Text(percent)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(window.isAtLimit ? PanelInk.limit(colorScheme) : PanelInk.primary(colorScheme))
            }
            UsageBar(percent: window.usedPercent)
                .padding(.vertical, 4)
            Text(meta)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(window.isNearLimit ? PanelInk.primary(colorScheme) : PanelInk.secondary(colorScheme))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.title), \(percent), \(meta)")
    }

    private var percent: String {
        let text = "\(Int(window.usedPercent.rounded()))%"
        return window.origin == .estimate ? "\(text) est." : text
    }

    private var meta: String {
        guard let resets = window.resetsAt else {
            return window.origin == .estimate ? "est." : ""
        }
        let line = window.showsCountdown
            ? ResetCopy.fiveHourLine(resets, now: now)
            : ResetCopy.weeklyLine(resets)
        return window.origin == .estimate ? "est. · \(line)" : line
    }
}

struct UsageBar: View {
    var percent: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width * min(1, max(0, percent / 100))
            ZStack(alignment: .leading) {
                Capsule().fill(PanelInk.separator(colorScheme))
                Capsule()
                    .fill(percent >= 90 ? PanelInk.limit(colorScheme) : PanelInk.primary(colorScheme))
                    .frame(width: width)
            }
        }
        .frame(height: PanelChrome.grid / 2)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: percent)
        .accessibilityValue("\(Int(percent.rounded())) percent")
    }
}

struct SessionRow: View {
    @Environment(TidepoolStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    var session: TrackedSession
    var expanded: Bool
    var now: Date
    var namespace: Namespace.ID
    var cursorInstalled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PanelChrome.grid) {
            Button {
                store.toggleExpanded(session.id)
            } label: {
                VStack(alignment: .leading, spacing: PanelChrome.grid) {
                    HStack(spacing: PanelChrome.grid) {
                        StatusDot(activity: session.activity)
                        Text(session.repo)
                            .font(.body)
                            .foregroundStyle(PanelInk.primary(colorScheme))
                            .lineLimit(1)
                        if let branch = session.branch {
                            BranchLabel(branch)
                        }
                        Spacer(minLength: PanelChrome.grid)
                        Text(statusText)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(session.activity == .needsYou ? PanelInk.needsYou(colorScheme) : PanelInk.secondary(colorScheme))
                    }
                    .frame(minHeight: PanelChrome.control)
                    if expanded, let waiting = waitingLine {
                        Text(waiting)
                            .font(.caption)
                            .foregroundStyle(PanelInk.secondary(colorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, PanelChrome.grid)
                .frame(maxWidth: .infinity, minHeight: PanelChrome.control, alignment: .leading)
            }
            .buttonStyle(.plain)
            .tidepoolGlass(
                id: "session-\(session.id)",
                namespace: namespace,
                shape: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            if expanded {
                HStack(spacing: PanelChrome.grid) {
                    Button {
                        if let cwd = session.cwd { SessionOpener.openTerminal(cwd) }
                    } label: {
                        Label("Open Terminal", systemImage: "terminal")
                            .font(.subheadline)
                            .frame(minHeight: PanelChrome.control)
                    }
                    .panelIconButton()
                    .disabled(session.cwd == nil)
                    Button {
                        if let cwd = session.cwd { SessionOpener.openCursor(cwd) }
                    } label: {
                        Label("Open in Cursor", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.subheadline)
                            .frame(minHeight: PanelChrome.control)
                    }
                    .panelIconButton()
                    .disabled(session.cwd == nil || !cursorInstalled)
                }
            }
        }
    }

    private var statusText: String {
        let estimated = session.origin == .estimate
        switch session.activity {
        case .needsYou:
            return estimated ? "Needs you (est.)" : "Needs you"
        case .working:
            return estimated ? "Working (est.)" : "Working"
        case .idle:
            let label = IdleFormat.label(since: session.idleSince, now: now)
            return estimated ? "\(label) (est.)" : label
        }
    }

    private var waitingLine: String? {
        guard session.activity == .needsYou else { return nil }
        if session.origin == .estimate {
            return "Waiting on you (est.)"
        }
        if session.toolName == "Bash", let detail = session.waitingDetail {
            return "Waiting on permission: run \(detail)"
        }
        if let detail = session.waitingDetail, session.toolName != nil {
            return "Waiting on permission: \(detail)"
        }
        return session.waitingDetail ?? "Waiting on you"
    }
}

struct StatusDot: View {
    var activity: SessionActivity
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch activity {
        case .needsYou:
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(PanelInk.needsYou(colorScheme))
        case .working:
            Image(systemName: "circle.dotted")
                .font(.system(size: 10))
                .foregroundStyle(PanelInk.secondary(colorScheme))
        case .idle:
            Image(systemName: "circle")
                .font(.system(size: 8))
                .foregroundStyle(PanelInk.separator(colorScheme))
        }
    }
}

struct BranchLabel: View {
    var name: String
    @Environment(\.colorScheme) private var colorScheme

    init(_ name: String) {
        self.name = name
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9))
            Text(name)
                .lineLimit(1)
        }
        .font(.caption.monospaced())
        .foregroundStyle(PanelInk.secondary(colorScheme))
    }
}

private struct PanelIconButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(.glass)
    }
}

private struct TidepoolGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var id: String
    var namespace: Namespace.ID
    var shape: S

    func body(content: Content) -> some View {
        if reduceMotion {
            content
                .glassEffect(.regular.interactive(), in: shape)
                .glassEffectID(id, in: namespace)
        } else {
            content
                .glassEffect(.regular.interactive(), in: shape)
                .glassEffectID(id, in: namespace)
                .glassEffectTransition(.matchedGeometry)
        }
    }
}

extension View {
    func panelIconButton() -> some View {
        modifier(PanelIconButtonModifier())
    }

    func tidepoolGlass<S: Shape>(id: String, namespace: Namespace.ID, shape: S) -> some View {
        modifier(TidepoolGlassModifier(id: id, namespace: namespace, shape: shape))
    }
}
