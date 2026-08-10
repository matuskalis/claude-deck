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
                if let badge {
                    Text(badge).monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }

    /// The status item is rendered as a template image, so state has to be carried by the
    /// symbol and the badge rather than by colour.
    private var symbol: String {
        let store = delegate.store
        if store.waitingCount > 0 { return "exclamationmark.bubble.fill" }
        if store.blockedJobCount > 0 { return "pause.circle.fill" }
        if store.wifi.present, !store.wifi.connected { return "wifi.slash" }
        if let worst = store.usage.worst, Severity(api: worst.severity, percent: worst.percent) == .critical {
            return "exclamationmark.triangle.fill"
        }
        return store.busyCount > 0 ? "terminal.fill" : "terminal"
    }

    /// Busy count first, then the tightest plan limit once it is worth knowing about.
    private var badge: String? {
        let store = delegate.store
        var parts: [String] = []
        if store.busyCount > 0 { parts.append("\(store.busyCount)") }
        if let worst = store.usage.worst,
           Severity(api: worst.severity, percent: worst.percent) != .normal {
            parts.append("\(worst.percent)%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "·")
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
