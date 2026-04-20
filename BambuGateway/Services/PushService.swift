#if os(iOS)
import ActivityKit
import Foundation
import UIKit
import UserNotifications

@MainActor
final class PushService {
    private let client: GatewayClient
    private let deviceIdDefaultsKey = "PushService.deviceId"

    private(set) var deviceToken: String?
    private(set) var liveActivityStartToken: String?
    private(set) var capabilitiesEnabled = false

    init(client: GatewayClient) {
        self.client = client
    }

    var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdDefaultsKey) {
            return existing
        }
        let id = "ios-\(UUID().uuidString)"
        UserDefaults.standard.set(id, forKey: deviceIdDefaultsKey)
        return id
    }

    func bootstrap() async {
        do {
            let caps = try await client.fetchCapabilities()
            capabilitiesEnabled = caps.push
            guard capabilitiesEnabled else { return }
        } catch {
            capabilitiesEnabled = false
            return
        }

        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return }

        await UIApplication.shared.registerForRemoteNotifications()

        Task {
            for await tokenData in Activity<PrintActivityAttributes>.pushToStartTokenUpdates {
                await handlePushToStartToken(tokenData)
            }
        }
    }

    func handleAPNsDeviceToken(_ tokenData: Data) async {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        await registerIfReady()
    }

    private func handlePushToStartToken(_ tokenData: Data) async {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        liveActivityStartToken = token
        await registerIfReady()
    }

    private func registerIfReady() async {
        guard capabilitiesEnabled, let deviceToken else { return }
        let payload = DeviceRegisterPayload(
            id: deviceId,
            name: UIDevice.current.name,
            deviceToken: deviceToken,
            liveActivityStartToken: liveActivityStartToken,
            subscribedPrinters: ["*"]
        )
        do {
            try await client.registerDevice(payload)
        } catch {
            // Fail silently; retry on next launch
        }
    }
}
#endif
