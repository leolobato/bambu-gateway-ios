#if os(iOS)
import ActivityKit
import Foundation

@MainActor
final class LiveActivityService {
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
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if activities[printerId] != nil { return }

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
            tokenObservers[printerId] = Task { [weak self] in
                for await tokenData in activity.pushTokenUpdates {
                    let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                    await self?.registerUpdateToken(printerId: printerId, token: hex)
                }
            }
        } catch {
            // ActivityKit refused; silently skip
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
        guard let pushService, pushService.capabilitiesEnabled else { return }
        do {
            try await client.registerActivity(
                deviceId: pushService.deviceId,
                payload: ActivityRegisterPayload(
                    printerId: printerId,
                    activityUpdateToken: token
                )
            )
        } catch {
            // Retry handled by next token rotation
        }
    }
}
#endif
