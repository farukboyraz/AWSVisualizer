import Foundation
import UserNotifications

/// Notifies the user the moment an AWS call comes back "Not Authorized" -
/// reactive, not a background poll. `APIService`'s central response
/// handling calls `reportNotAuthorized()` every time any request fails
/// with 401/403, so this fires right when (and only when) the session
/// actually stops working, instead of the user discovering it later as a
/// confusing error in some unrelated view. Debounced so a burst of calls
/// failing around the same moment (several views' in-flight requests all
/// hitting the same expired session) only produces one notification.
actor SessionExpiryMonitor {
    static let shared = SessionExpiryMonitor()

    private var lastNotifiedAt: Date?
    private let cooldown: TimeInterval = 5 * 60

    private init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func reportNotAuthorized() {
        // Always tell the UI (it debounces its own profile re-check);
        // only the user-facing notification below is rate-limited here.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .awsRequestNotAuthorized, object: nil)
        }
        let now = Date()
        if let last = lastNotifiedAt, now.timeIntervalSince(last) < cooldown {
            return
        }
        lastNotifiedAt = now
        notify()
    }

    nonisolated private func notify() {
        let content = UNMutableNotificationContent()
        content.title = "AWS Session Expired"
        content.body = "Your AWS session is no longer authorized. Log in again to keep using AWS Visualizer."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "aws-session-expired-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
