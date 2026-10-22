import HookBridge
import SwiftUI
import UserNotifications

enum NotificationHub {
    @MainActor static let presenter = NotificationPresenter()
}

@main
struct TidepoolApp: App {
    @State private var store = TidepoolStore()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
