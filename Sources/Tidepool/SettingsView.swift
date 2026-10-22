import ProviderKit
import SwiftUI

struct SettingsView: View {
    @Environment(TidepoolStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    withAnimation(reduceMotion ? nil : .smooth) {
                        store.showingSettings = false
                    }
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Back")
                Text("Settings")
                    .font(.body.weight(.semibold))
                Spacer()
            }
            Toggle("Notifications when a session needs you", isOn: notifications)
            Toggle("Launch at login", isOn: launch)
            Toggle("Claude Code hooks", isOn: hooks)
            VStack(alignment: .leading, spacing: 4) {
                Text("Menu bar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Menu bar", selection: format) {
                    ForEach(MenuBarFormat.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            Stepper(value: refresh, in: 60...600, step: 30) {
                Text("Refresh every \(Int(store.refreshSeconds))s")
                    .font(.body)
                    .monospacedDigit()
            }
            if let burn = store.snapshot.today.blockTokensPerHour {
                Text("Current block ≈ \(TokenFormat.compact(Int(burn))) tokens/hour (est.)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Divider()
            Text("Tools")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(store.catalog) { tool in
                HStack {
                    Text(tool.displayName)
                        .font(.body)
                    Spacer()
                    Text(label(tool))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let notice = store.actionNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 320)
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
        switch tool.state {
        case .active: "Active"
        case .comingSoon: "Detected · coming soon"
        case .notDetected: "Not detected"
        case .undetectable: tool.note ?? "No install marker"
        }
    }
}
