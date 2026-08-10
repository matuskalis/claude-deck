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

    /// A background job that is blocked will sit there forever, and there is no terminal
    /// window anywhere showing that it is waiting.
    func jobBlocked(job: Job) {
        post(
            identifier: "job-\(job.id)",
            title: "⏸ \(job.name) is blocked",
            body: job.waitingOn ?? "Waiting for you"
        )
    }

    func usageThreshold(limit: UsageLimit, threshold: Int) {
        post(
            identifier: "usage-\(limit.id)-\(threshold)",
            title: "\(limit.title) usage at \(limit.percent)%",
            body: limit.resetsAt.map { "Resets \(Self.relative.localizedString(for: $0, relativeTo: Date()))" }
                ?? limit.subtitle
        )
    }

    func wifiDropped() {
        post(
            identifier: "wifi-dropped",
            title: "Wi-Fi dropped",
            body: "Running sessions will fail their next request."
        )
    }

    func wifiRestored() {
        center.removeDeliveredNotifications(withIdentifiers: ["wifi-dropped"])
    }

    private static let relative = RelativeDateTimeFormatter()

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
