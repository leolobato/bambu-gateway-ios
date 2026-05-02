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
        adoptExistingActivities()
        observeActivityUpdates()
    }

    /// Returns true if a Live Activity is currently live for the given printer.
    /// Dismissed or ended activities don't count — callers should recreate.
    func hasActivity(for printerId: String) -> Bool {
        guard let activity = activities[printerId] else { return false }
        return activity.activityState == .active || activity.activityState == .stale
    }

    /// Starts or reuses a Live Activity for the given printer/job.
    func startActivity(
        printerId: String,
        printerName: String,
        fileName: String,
        thumbnail: Data?,
        showPrinterName: Bool,
        initialState: PrintActivityAttributes.ContentState
    ) async {
        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
        Self.log.info("startActivity: printerId=\(printerId, privacy: .public) fileName=\(fileName, privacy: .public) areActivitiesEnabled=\(enabled, privacy: .public)")
        guard enabled else {
            Self.log.error("startActivity: skipped, Live Activities not enabled (check NSSupportsLiveActivities and system toggle)")
            return
        }
        if let existing = Activity<PrintActivityAttributes>.activities.first(where: {
            $0.attributes.printerId == printerId &&
            ($0.activityState == .active || $0.activityState == .stale)
        }) {
            Self.log.info("startActivity: adopting live system activity id=\(existing.id, privacy: .public) for printerId=\(printerId, privacy: .public)")
            adopt(existing)
            return
        }

        let attrs = PrintActivityAttributes(
            printerId: printerId,
            printerName: printerName,
            fileName: fileName,
            thumbnailData: thumbnail,
            showPrinterName: showPrinterName
        )
        do {
            let activity = try Activity.request(
                attributes: attrs,
                content: .init(state: initialState, staleDate: nil),
                pushType: .token
            )
            activities[printerId] = activity
            Self.log.info("startActivity: requested id=\(activity.id, privacy: .public) for printerId=\(printerId, privacy: .public)")
            observePushToken(printerId: printerId, activity: activity)
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

    private func adoptExistingActivities() {
        var keeper: [String: Activity<PrintActivityAttributes>] = [:]
        var duplicates: [Activity<PrintActivityAttributes>] = []
        for activity in Activity<PrintActivityAttributes>.activities {
            guard activity.activityState == .active || activity.activityState == .stale else { continue }
            let printerId = activity.attributes.printerId
            if keeper[printerId] == nil {
                keeper[printerId] = activity
            } else {
                duplicates.append(activity)
            }
        }
        for activity in duplicates {
            Self.log.info("adoptExistingActivities: ending duplicate id=\(activity.id, privacy: .public) printerId=\(activity.attributes.printerId, privacy: .public)")
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        for activity in keeper.values {
            Self.log.info("adoptExistingActivities: adopting id=\(activity.id, privacy: .public) printerId=\(activity.attributes.printerId, privacy: .public)")
            adopt(activity)
        }
    }

    private func adopt(_ activity: Activity<PrintActivityAttributes>) {
        let printerId = activity.attributes.printerId
        activities[printerId] = activity
        observePushToken(printerId: printerId, activity: activity)
    }

    /// Observes activities the system creates from a push-to-start. Without
    /// this, prints kicked off outside the app (e.g. from OrcaSlicer) start
    /// the Live Activity but never register their per-activity update token,
    /// so the gateway has nothing to push subsequent updates to.
    private func observeActivityUpdates() {
        Task { [weak self] in
            for await activity in Activity<PrintActivityAttributes>.activityUpdates {
                await self?.handleActivityUpdate(activity)
            }
        }
    }

    private func handleActivityUpdate(_ activity: Activity<PrintActivityAttributes>) {
        let printerId = activity.attributes.printerId
        if let existing = activities[printerId], existing.id == activity.id {
            return
        }
        Self.log.info("activityUpdates: adopting id=\(activity.id, privacy: .public) printerId=\(printerId, privacy: .public)")
        adopt(activity)
    }

    private func observePushToken(printerId: String, activity: Activity<PrintActivityAttributes>) {
        tokenObservers[printerId]?.cancel()
        tokenObservers[printerId] = Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                await self?.registerUpdateToken(printerId: printerId, token: hex)
            }
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
