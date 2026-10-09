import AppKit
import UserNotifications

/// Tells the person a long sort, undo or cleanup finished while the panel was closed.
/// Clicking the notification opens the panel.
@MainActor
final class FinishNotifier: NSObject, UNUserNotificationCenterDelegate {
    var isPanelOpen: () -> Bool = { false }
    var onClick: () -> Void = {}
    /// The notification center only exists for a process running from an app bundle.
    private let center = Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil

    func start() { center?.delegate = self }

    func post(_ title: String, _ body: String) {
        guard let center, !isPanelOpen(), UserDefaults.standard.bool(forKey: AppSettings.Key.notify) else { return }
        Task {
            // Asks the first time; afterwards macOS answers with the person's choice.
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        await MainActor.run { onClick() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
