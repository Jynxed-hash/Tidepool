import ProviderKit
import SwiftUI

struct PanelView: View {
    @Environment(TidepoolStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass

    var body: some View {
        Group {
            if store.showingSettings {
                SettingsView()
            } else {
                main
            }
        }
        .frame(width: 320)
    }

    private var main: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            GlassEffectContainer(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if store.snapshot.availability != .limited,
                       let attention = store.snapshot.sessions.first(where: { $0.activity == .needsYou }) {
                        attentionPill(attention)
                            .padding(.bottom, 12)
                    }
                    if let notice = store.snapshot.notice ?? store.actionNotice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 8)
                    }
                    if store.snapshot.availability != .limited {
                        usage(now: timeline.date)
                        if showsSessions {
                            sessions(now: timeline.date)
                        }
                    }
                    if !store.comingSoon.isEmpty {
                        Divider().padding(.vertical, 8)
                        Text("On this Mac")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                        ForEach(store.comingSoon) { tool in
                            Text("\(tool.displayName) · coming soon")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    footer
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private var animation: Animation? {
        reduceMotion ? nil : .smooth
    }

    private var header: some View {
        HStack(spacing: 6) {
            providerTitle
            if store.selectedIsUnofficial {
                unofficialBadge
            }
            Spacer(minLength: 8)
            Button {
                Task { await store.setNotifications(enabled: !store.notificationsEnabled) }
            } label: {
                Image(systemName: store.notificationsEnabled ? "bell" : "bell.slash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.glass)
            .accessibilityLabel(store.notificationsEnabled ? "Notifications on" : "Notifications off")
        }
        .padding(.bottom, 10)
    }

    private var unofficialBadge: some View {
        Text("Unofficial")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay {
                Capsule().strokeBorder(Color.secondary.opacity(0.45), lineWidth: 0.5)
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
                HStack(spacing: 4) {
                    Text(store.selectedTitle)
                        .font(.body.weight(.semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Provider, \(store.selectedTitle)")
        } else {
            Text(store.selectedTitle)
                .font(.body.weight(.semibold))
        }
    }

    private func attentionPill(_ session: TrackedSession) -> some View {
        Button {
            withAnimation(animation) { store.focusNeedsYou() }
        } label: {
            HStack(spacing: 7) {
                StatusDot(activity: .needsYou)
                Text(session.repo)
                    .foregroundStyle(.primary)
                if let branch = session.branch {
                    BranchLabel(branch)
                }
                Spacer(minLength: 8)
                Text("Needs you")
                    .foregroundStyle(.orange)
            }
            .font(.body)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .tidepoolGlass(id: "pill-\(session.id)", namespace: glass, shape: Capsule(), reduceMotion: reduceMotion)
    }

    private func usage(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.snapshot.windows.isEmpty {
                if store.snapshot.providerID == ToolCatalog.claudeCode {
                    Text("Usage appears after Claude Code is signed in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(store.snapshot.windows) { window in
                    UsageRow(window: window, now: now)
                }
            }
        }
        .padding(.bottom, 12)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sessions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(sessionCount)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if store.snapshot.sessions.isEmpty {
                Text("No sessions right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
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

    private var sessionCount: String {
        let count = store.snapshot.sessions.count
        return count == 1 ? "1 active" : "\(count) active"
    }

    private var showsToday: Bool {
        if store.snapshot.availability == .limited { return false }
        if store.snapshot.providerID == ToolCatalog.claudeCode { return true }
        return store.snapshot.today.tokens > 0 || store.snapshot.today.costUSD != nil
    }

    private var footer: some View {
        HStack(alignment: .center) {
            if showsToday {
                Text(TokenFormat.todayLine(store.snapshot.today))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            Button {
                withAnimation(animation) { store.showingSettings.toggle() }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Settings")
        }
        .padding(.top, 8)
    }
}

struct UsageRow: View {
    var window: UsageWindow
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(window.title)
                    .font(.body)
                Spacer()
                Text(percent)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(window.isAtLimit ? Color.red : Color.primary)
            }
            UsageBar(percent: window.usedPercent)
                .padding(.vertical, 6)
            Text(meta)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(window.isNearLimit ? Color.primary : Color.secondary)
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

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width * min(1, max(0, percent / 100))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(percent >= 90 ? Color.red : Color.primary.opacity(0.85))
                    .frame(width: width)
            }
        }
        .frame(height: 4)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: percent)
        .accessibilityValue("\(Int(percent.rounded())) percent")
    }
}

struct SessionRow: View {
    @Environment(TidepoolStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var session: TrackedSession
    var expanded: Bool
    var now: Date
    var namespace: Namespace.ID
    var cursorInstalled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : .smooth) {
                    store.toggleExpanded(session.id)
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        StatusDot(activity: session.activity)
                        Text(session.repo)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let branch = session.branch {
                            BranchLabel(branch)
                        }
                        Spacer(minLength: 6)
                        Text(statusText)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(session.activity == .needsYou ? Color.orange : Color.secondary)
                    }
                    .frame(minHeight: 28)
                    if expanded, let waiting = waitingLine {
                        Text(waiting)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .tidepoolGlass(
                id: "session-\(session.id)",
                namespace: namespace,
                shape: RoundedRectangle(cornerRadius: 12, style: .continuous),
                reduceMotion: reduceMotion
            )
            if expanded {
                HStack(spacing: 6) {
                    Button {
                        if let cwd = session.cwd { SessionOpener.openTerminal(cwd) }
                    } label: {
                        Label("Open Terminal", systemImage: "terminal")
                            .font(.caption)
                    }
                    .buttonStyle(.glass)
                    .disabled(session.cwd == nil)
                    Button {
                        if let cwd = session.cwd { SessionOpener.openCursor(cwd) }
                    } label: {
                        Label("Open in Cursor", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.caption)
                    }
                    .buttonStyle(.glass)
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

    var body: some View {
        switch activity {
        case .needsYou:
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(.orange)
        case .working:
            Image(systemName: "circle.dotted")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        case .idle:
            Image(systemName: "circle")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
    }
}

struct BranchLabel: View {
    var name: String

    init(_ name: String) {
        self.name = name
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9))
            Text(name)
                .lineLimit(1)
        }
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
    }
}

extension View {
    @ViewBuilder
    func tidepoolGlass<S: Shape>(
        id: String,
        namespace: Namespace.ID,
        shape: S,
        reduceMotion: Bool
    ) -> some View {
        if reduceMotion {
            self.glassEffect(.regular.interactive(), in: shape)
                .glassEffectID(id, in: namespace)
        } else {
            self.glassEffect(.regular.interactive(), in: shape)
                .glassEffectID(id, in: namespace)
                .glassEffectTransition(.matchedGeometry)
        }
    }
}
