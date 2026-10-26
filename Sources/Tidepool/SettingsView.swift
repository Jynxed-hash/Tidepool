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
                .font(.body)
                .foregroundStyle(PanelInk.secondary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: PanelChrome.grid) {
                Text("Menu bar")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PanelInk.secondary(colorScheme))
                Picker("Menu bar", selection: format) {
                    ForEach(MenuBarFormat.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .controlSize(.large)
            }
            Stepper(value: refresh, in: 60...600, step: 30) {
                Text("Refresh every \(Int(store.refreshSeconds))s")
                    .font(.body)
                    .foregroundStyle(PanelInk.primary(colorScheme))
                    .monospacedDigit()
            }
            .frame(minHeight: PanelChrome.control)
            if let burn = store.snapshot.today.blockTokensPerHour {
                Text("Current block ≈ \(TokenFormat.compact(Int(burn))) tokens/hour (est.)")
                    .font(.subheadline)
                    .foregroundStyle(PanelInk.secondary(colorScheme))
                    .monospacedDigit()
            }
            Text("Tools")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PanelInk.secondary(colorScheme))
                .padding(.top, PanelChrome.grid)
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
        .padding(.bottom, PanelChrome.margin)
        .frame(width: PanelChrome.width, alignment: .topLeading)
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
