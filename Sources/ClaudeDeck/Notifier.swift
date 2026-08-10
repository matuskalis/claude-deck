import Foundation
import UserNotifications

/// UNUserNotificationCenter only works from a real app bundle; see the Makefile,
/// which assembles dist/Claude Deck.app around the SwiftPM binary.
@MainActor
final class Notifier {
    private let center = UNUserNotificationCenter.current()
    private var lastPermissionAlert: [String: Date] = [:]

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Banners fail silently when macOS has notifications turned off for the app,
    /// which is worth telling the user about.
    func isBlocked() async -> Bool {
        await center.notificationSettings().authorizationStatus == .denied
    }

    func permissionNeeded(sessionId: String, project: String, message: String?) {
        let now = Date()
        if let last = lastPermissionAlert[sessionId], now.timeIntervalSince(last) < 5 { return }
        lastPermissionAlert[sessionId] = now

        post(
            identifier: "perm-\(sessionId)",
            title: "⏸ \(project) needs you",
            body: message ?? "Waiting for your approval"
        )
    }

    func sessionFinished(sessionId: String, name: String, project: String) {
        post(
            identifier: "done-\(sessionId)-\(Int(Date().timeIntervalSince1970 * 1000))",
            title: "✅ \(name) finished",
            body: project
        )
    }

    func clearPermissionAlert(sessionId: String) {
        lastPermissionAlert[sessionId] = nil
        center.removeDeliveredNotifications(withIdentifiers: ["perm-\(sessionId)"])
    }

    private func post(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { _ in }
    }
}
