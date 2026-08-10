import SwiftUI
import UserNotifications

@main
struct ClaudeDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: delegate.store)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                if delegate.store.busyCount > 0 {
                    Text("\(delegate.store.busyCount)")
                }
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var symbol: String {
        if delegate.store.waitingCount > 0 { return "exclamationmark.bubble.fill" }
        return delegate.store.busyCount > 0 ? "terminal.fill" : "terminal"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = SessionStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        store.start()
    }

    /// The app has no window, so banners have to be requested explicitly.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
