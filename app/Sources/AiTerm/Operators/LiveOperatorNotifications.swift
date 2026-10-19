import Foundation
import UserNotifications

/// macOS's notification centre. Reached only once something is posted or authorised: a process
/// without a bundle identifier has no centre, and asking for one would trap — the snapshot renderer
/// builds the live wiring and never posts.
@MainActor
final class LiveOperatorNotifications: NSObject, OperatorNotifications {
    var onOpen: (@MainActor (OperatorNote.Target) -> Void)?
    private var asked = false

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func requestAuthorization() {
        guard !asked, let center else { return }
        asked = true
        center.delegate = self
        // The async form: its completion never runs inside this main-actor class, where a closure
        // the SDK does not mark @Sendable would trap when the centre calls it off the main queue.
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
    }

    func post(_ note: OperatorNote) {
        guard let center else { return }
        if center.delegate == nil { center.delegate = self }
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        content.userInfo = note.target.userInfo
        center.add(UNNotificationRequest(identifier: note.id, content: content, trigger: nil))
    }

    func readDelivered() async -> [String] {
        guard center != nil else { return [] }
        return await Self.deliveredIds()
    }

    /// Read off the main actor: the centre calls its completion on its own queue.
    private nonisolated static func deliveredIds() async -> [String] {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getDeliveredNotifications { continuation.resume(returning: $0.map { $0.request.identifier }) }
        }
    }

    func withdraw(ids: [String]) {
        guard let center, !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

extension LiveOperatorNotifications: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let target = OperatorNote.Target(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run { self.onOpen?(target) }
    }

    /// Shown while AiTerm is in front too: the sidebar may be all you are looking at.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
