#if os(iOS)
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var pushService: PushService?
    static var toastCenter: ToastCenter?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            await Self.pushService?.handleAPNsDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Ignore — push just won't work this session
    }

    // Forward foreground notifications into our in-app toast so users see
    // something even when iOS would normally suppress the banner.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        Task { @MainActor in
            Self.toastCenter?.show(title: content.title, body: content.body)
        }
        // Suppress the native banner — the toast replaces it while foreground.
        completionHandler([.sound])
    }
}
#endif
