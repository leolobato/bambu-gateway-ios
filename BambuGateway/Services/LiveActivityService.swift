#if os(iOS)
import ActivityKit
import Foundation
import OSLog

@MainActor
final class LiveActivityService {
    private static let log = Logger(subsystem: "com.bambugateway.ios", category: "LiveActivityService")

    private let client: GatewayClient
    private weak var pushService: PushService?
    private var activities: [String: Activity<PrintActivityAttributes>] = [:]
    private var tokenObservers: [String: Task<Void, Never>] = [:]

    init(client: GatewayClient, pushService: PushService?) {
        self.client = client
        self.pushService = pushService
    }

    /// Starts or reuses a Live Activity for the given printer/job.
    func startActivity(
        printerId: String,
        printerName: String,
        fileName: String,
        thumbnail: Data?,
        initialState: PrintActivityAttributes.ContentState
    ) async {
        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
        Self.log.info("startActivity: printerId=\(printerId, privacy: .public) fileName=\(fileName, privacy: .public) areActivitiesEnabled=\(enabled, privacy: .public)")
        guard enabled else {
            Self.log.error("startActivity: skipped, Live Activities not enabled (check NSSupportsLiveActivities and system toggle)")
            return
        }
        if activities[printerId] != nil {
            Self.log.info("startActivity: already running for printerId=\(printerId, privacy: .public), skipping")
            return
        }

        let attrs = PrintActivityAttributes(
            printerId: printerId,
            printerName: printerName,
            fileName: fileName,
            thumbnailData: thumbnail
        )
        do {
            let activity = try Activity.request(
                attributes: attrs,
                content: .init(state: initialState, staleDate: nil),
                pushType: .token
            )
            activities[printerId] = activity
            Self.log.info("startActivity: requested id=\(activity.id, privacy: .public) for printerId=\(printerId, privacy: .public)")
            tokenObservers[printerId] = Task { [weak self] in
                for await tokenData in activity.pushTokenUpdates {
                    let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                    await self?.registerUpdateToken(printerId: printerId, token: hex)
                }
            }
        } catch {
            Self.log.error("startActivity: Activity.request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func updateActivity(
        printerId: String,
        state: PrintActivityAttributes.ContentState
    ) async {
        guard let activity = activities[printerId] else { return }
        await activity.update(.init(state: state, staleDate: nil))
    }

    func endActivity(
        printerId: String,
        finalState: PrintActivityAttributes.ContentState,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) async {
        guard let activity = activities[printerId] else { return }
        await activity.end(
            .init(state: finalState, staleDate: nil),
            dismissalPolicy: dismissalPolicy
        )
        activities.removeValue(forKey: printerId)
        tokenObservers[printerId]?.cancel()
        tokenObservers.removeValue(forKey: printerId)

        if let pushService, pushService.capabilitiesEnabled {
            try? await client.unregisterActivity(
                deviceId: pushService.deviceId,
                printerId: printerId
            )
        }
    }

    private func registerUpdateToken(printerId: String, token: String) async {
        Self.log.info("activity pushToken update printerId=\(printerId, privacy: .public) token=\(token, privacy: .public)")
        guard let pushService, pushService.capabilitiesEnabled else {
            Self.log.debug("registerUpdateToken: skipped (capabilitiesEnabled=\(self.pushService?.capabilitiesEnabled ?? false, privacy: .public))")
            return
        }
        do {
            try await client.registerActivity(
                deviceId: pushService.deviceId,
                payload: ActivityRegisterPayload(
                    printerId: printerId,
                    activityUpdateToken: token
                )
            )
            Self.log.info("registerActivity: success printerId=\(printerId, privacy: .public)")
        } catch {
            Self.log.error("registerActivity: failed printerId=\(printerId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
