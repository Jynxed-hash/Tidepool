import ProviderKit
import SwiftUI

struct SettingsView: View {
    @Environment(TidepoolStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: PanelChrome.grid) {
            toggle("Notifications when a session needs you", isOn: notifications)
            toggle("Launch at login", isOn: launch)
            toggle("Claude Code hooks", isOn: hooks)
            toggle("Unofficial providers", isOn: unofficial)
            Text("Cursor and GitHub Copilot use undocumented endpoints. Turning this off skips those calls.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 22)
            sectionHeader("Menu bar")
            Picker("Menu bar", selection: format) {
                ForEach(MenuBarFormat.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .controlSize(.large)
            sectionHeader("Refresh")
            Picker("Refresh", selection: refresh) {
                Text("30s").tag(30.0)
                Text("60s").tag(60.0)
                Text("90s").tag(90.0)
                Text("5m").tag(300.0)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(minHeight: PanelChrome.control, alignment: .leading)
            if let burn = store.snapshot.today.blockTokensPerHour {
                Text("Current block ≈ \(TokenFormat.compact(Int(burn))) tokens/hour (est.)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            sectionHeader("Tools")
            ForEach(store.catalog) { tool in
                HStack {
                    Text(tool.displayName)
                        .font(.body)
                        .foregroundStyle(PanelInk.primary(colorScheme))
                    Spacer()
                    Text(label(tool))
                        .font(.subheadline)
                        .foregroundStyle(PanelInk.secondary(colorScheme))
                }
                .frame(minHeight: PanelChrome.control)
            }
            if let notice = store.actionNotice {
                Text(notice)
                    .font(.body)
                    .foregroundStyle(PanelInk.secondary(colorScheme))
            }
        }
        .padding(.horizontal, PanelChrome.margin)
        .padding(.bottom, PanelChrome.grid)
        .frame(width: PanelChrome.width, alignment: .topLeading)
    }

    /// 20 points above the label, 8 below, from the surrounding 8-point stack.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PanelInk.secondary(colorScheme))
            .padding(.top, 12)
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .font(.body)
            .foregroundStyle(PanelInk.primary(colorScheme))
            .frame(minHeight: PanelChrome.control)
            .controlSize(.large)
    }

    private var notifications: Binding<Bool> {
        Binding(
            get: { store.notificationsEnabled },
            set: { enabled in Task { await store.setNotifications(enabled: enabled) } }
        )
    }

    private var launch: Binding<Bool> {
        Binding(
            get: { store.launchAtLogin },
            set: { store.setLaunchAtLogin($0) }
        )
    }

    private var unofficial: Binding<Bool> {
        Binding(
            get: { store.unofficialProvidersEnabled },
            set: { store.setUnofficialProviders($0) }
        )
    }

    private var hooks: Binding<Bool> {
        Binding(
            get: { store.hooksEnabled },
            set: { store.setHooks(enabled: $0) }
        )
    }

    private var format: Binding<MenuBarFormat> {
        Binding(
            get: { store.menuFormat },
            set: { store.setMenuFormat($0) }
        )
    }

    private var refresh: Binding<Double> {
        Binding(
            get: { store.refreshSeconds },
            set: { store.setRefreshSeconds($0) }
        )
    }

    private func label(_ tool: CatalogStatus) -> String {
        if tool.unofficial && tool.state == .active && !store.unofficialProvidersEnabled {
            return "Off"
        }
        switch tool.state {
        case .active: return tool.unofficial ? "Active · Unofficial" : "Active"
        case .comingSoon: return "Detected · coming soon"
        case .notDetected: return "Not detected"
        case .undetectable: return tool.note ?? "No install marker"
        case .limitedData: return "Limited data"
        }
    }
}
