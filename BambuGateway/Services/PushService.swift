#if os(iOS)
import ActivityKit
import Foundation
import OSLog
import UIKit
import UserNotifications

@MainActor
final class PushService {
    private static let log = Logger(subsystem: "com.bambugateway.ios", category: "PushService")

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
        Self.log.info("bootstrap: starting, deviceId=\(self.deviceId, privacy: .public)")
        do {
            let caps = try await client.fetchCapabilities()
            capabilitiesEnabled = caps.push
            Self.log.info("bootstrap: capabilities push=\(caps.push, privacy: .public) liveActivities=\(caps.liveActivities, privacy: .public)")
            guard capabilitiesEnabled else { return }
        } catch {
            capabilitiesEnabled = false
            Self.log.error("bootstrap: fetchCapabilities failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        Self.log.info("bootstrap: UN authorization granted=\(granted, privacy: .public)")
        guard granted else { return }

        await UIApplication.shared.registerForRemoteNotifications()
        Self.log.info("bootstrap: requested APNs registration")

        Task {
            for await tokenData in Activity<PrintActivityAttributes>.pushToStartTokenUpdates {
                await handlePushToStartToken(tokenData)
            }
        }
    }

    func handleAPNsDeviceToken(_ tokenData: Data) async {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        Self.log.info("received APNs device token=\(token, privacy: .public)")
        await registerIfReady()
    }

    private func handlePushToStartToken(_ tokenData: Data) async {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        liveActivityStartToken = token
        Self.log.info("received Live Activity push-to-start token=\(token, privacy: .public)")
        await registerIfReady()
    }

    private func registerIfReady() async {
        guard capabilitiesEnabled, let deviceToken else {
            Self.log.debug("registerIfReady: skipped (capabilitiesEnabled=\(self.capabilitiesEnabled, privacy: .public), hasDeviceToken=\(self.deviceToken != nil, privacy: .public))")
            return
        }
        let payload = DeviceRegisterPayload(
            id: deviceId,
            name: UIDevice.current.name,
            deviceToken: deviceToken,
            liveActivityStartToken: liveActivityStartToken,
            subscribedPrinters: ["*"]
        )
        Self.log.info("registering device id=\(payload.id, privacy: .public) name=\(payload.name, privacy: .public) deviceToken=\(payload.deviceToken, privacy: .public) liveActivityStartToken=\(payload.liveActivityStartToken ?? "nil", privacy: .public)")
        do {
            try await client.registerDevice(payload)
            Self.log.info("registerDevice: success")
        } catch {
            Self.log.error("registerDevice: failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
