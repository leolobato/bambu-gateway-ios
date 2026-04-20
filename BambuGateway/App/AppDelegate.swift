#if os(iOS)
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var pushService: PushService?

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
}
#endif
