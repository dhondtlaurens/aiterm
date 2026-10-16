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
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
