import Foundation
import GCodePreview
import SceneKit
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    private struct StartedPrintContext: Equatable {
        let printerId: String
        let fileName: String
        let fileSize: Int
        let plateId: Int?
        let plateType: String
        let machineProfile: String
        let processProfile: String
        let filamentOverrides: [Int: FilamentOverrideSelection]
    }

    /// Persisted across app launches so a slice job in flight can be resumed
    /// after the app is killed. `kind` says what to do once the job is ready.
    private struct PendingSliceJob: Codable {
        let jobId: String
        let kind: String  // "preview" or "print"
    }

    private static let pendingSliceJobKey = "BambuGateway.pendingSliceJob"

    enum MessageLevel {
        case info
        case success
        case warning
        case error
    }

    @Published var gatewayBaseURL: String
    @Published var printers: [PrinterStatus] = []
    @Published var selectedPrinterId: String

    @Published var amsTrays: [AMSTray] = []
    @Published var amsUnits: [AMSUnit] = []
    @Published var vtTray: AMSTray?
    @Published var slicerFilaments: [SlicerProfile] = []
    @Published var amsAssignableFilaments: [SlicerProfile] = []

    @Published var machineOptions: [ProfileOption] = []
    @Published var processOptions: [ProfileOption] = []
    @Published var plateTypeOptions: [ProfileOption] = [ProfileOption(id: "", label: "Use file/default")]
    @Published var selectedMachineProfileId: String = ""
    @Published var selectedProcessProfileId: String = ""
    @Published var selectedPlateType: String = ""

    @Published var selectedFile: Imported3MFFile?
    @Published var parsedInfo: ThreeMFInfo?
    @Published var selectedPlateId: Int = 0

    @Published var trayProfileBySlot: [Int: String] = [:]
    @Published var filamentTrayByIndex: [Int: Int] = [:]

    @Published var selectedTab = 0
    @Published var makerWorldBrowserURL: URL?
    @Published var isShowingMakerWorldBrowser = false

    @Published var isLoading: Bool = false
    @Published var isParsing: Bool = false
    @Published var isSubmitting: Bool = false
    @Published var isLoadingPreview: Bool = false
    @Published var isShowingPreview: Bool = false
    @Published var previewScene: SCNScene?
    @Published var currentJobId: String?
    @Published var previewEstimate: PrintEstimate?
    /// 0–100 while a slice job is running for this client; nil otherwise.
    @Published var slicingProgress: Int?
    /// Human-readable phase from the gateway (e.g. "Optimizing toolpath").
    /// Nil when no slice job is in flight or the gateway hasn't reported one yet.
    @Published var slicingPhase: String?
    @Published var lastPrintEstimate: PrintEstimate?
    @Published var lastPrintPrinterName: String?
    /// Drives the one-shot success sheet shown after a direct print.
    /// Set together with `lastPrintEstimate` and `lastPrintPrinterName` in `submitPrint`;
    /// cleared together by `dismissPrintSuccessModal()`.
    @Published var showPrintSuccessModal: Bool = false
    @Published var message: String = ""
    @Published var messageLevel: MessageLevel = .info
    @Published var uploadProgress: Double? = nil
    @Published var isCancellingUpload: Bool = false
    @Published var isSpeedChangeInFlight: Bool = false
    @Published var chamberLightPending: Bool = false
    /// Set to the intended on/off state when a light toggle is in flight.
    /// Cleared once the server's reported state catches up, or on failure.
    /// `chamberLightOn` prefers this over the server value so the UI flips
    /// immediately instead of waiting for the next MQTT pushall.
    @Published var optimisticChamberLightOn: Bool?

    let pushService: PushService
    let liveActivityService: LiveActivityService
    let notificationService: NotificationService
    let toastCenter: ToastCenter
    let transferService: BackgroundTransferService

    private var previousStates: [String: String] = [:]

    private var uploadPollingTask: Task<Void, Never>?
    private var activeUploadId: String?
    private let settingsStore: AppSettingsStore
    private var persistedSettings: PersistedSettings
    private var allSlicerMachines: [SlicerProfile] = []
    private var slicerMachines: [SlicerProfile] = []
    private var allSlicerProcesses: [SlicerProfile] = []
    private var slicerProcesses: [SlicerProfile] = []
    private var allSlicerFilaments: [SlicerProfile] = []
    private var filamentMatchesByIndex: [Int: ProjectFilamentMatch] = [:]
    private var startedPrintContext: StartedPrintContext?

    private static let defaultPlateTypeOptions: [ProfileOption] = [
        ProfileOption(id: "", label: "Use file/default"),
        ProfileOption(id: "cool_plate", label: "Cool Plate"),
        ProfileOption(id: "engineering_plate", label: "Engineering Plate"),
        ProfileOption(id: "high_temp_plate", label: "High Temp Plate"),
        ProfileOption(id: "textured_pei_plate", label: "Textured PEI Plate"),
        ProfileOption(id: "textured_cool_plate", label: "Textured Cool Plate"),
        ProfileOption(id: "supertack_plate", label: "Supertack Plate"),
    ]

    init(settingsStore: AppSettingsStore = AppSettingsStore()) {
        self.settingsStore = settingsStore
        let loaded = settingsStore.load()
        self.persistedSettings = loaded
        self.gatewayBaseURL = loaded.gatewayBaseURL
        self.selectedPrinterId = loaded.selectedPrinterId

        let initialClient = GatewayClient(baseURLString: loaded.gatewayBaseURL)
        let push = PushService(client: initialClient)
        let toast = ToastCenter()
        let transfer = BackgroundTransferService()
        self.pushService = push
        self.liveActivityService = LiveActivityService(client: initialClient, pushService: push)
        self.notificationService = NotificationService()
        self.toastCenter = toast
        self.transferService = transfer
        AppDelegate.pushService = push
        AppDelegate.toastCenter = toast
        AppDelegate.transferService = transfer
    }

    func bootstrapPushServices() async {
        await notificationService.requestAuthorizationIfNeeded()
        await pushService.bootstrap()
    }

    var selectedPrinter: PrinterStatus? {
        if let explicit = printers.first(where: { $0.id == selectedPrinterId }) {
            return explicit
        }
        return printers.first
    }

    /// `true` when the chamber light is on, `false` when off, `nil` when unknown.
    /// An in-flight optimistic toggle takes precedence over the server value.
    var chamberLightOn: Bool? {
        optimisticChamberLightOn ?? selectedPrinter?.camera?.chamberLight?.on
    }

    /// `true` when the selected printer reports chamber-light as a supported feature.
    var chamberLightSupported: Bool {
        selectedPrinter?.camera?.chamberLight?.supported == true
    }

    var shouldAutoUseSinglePrinter: Bool {
        printers.count == 1
    }

    var hasParsedFile: Bool {
        parsedInfo != nil
    }

    var isGatewayConfigured: Bool {
        !gatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasMultiplePlates: Bool {
        (parsedInfo?.plates.count ?? 0) > 1
    }

    var hasStartedPrintForCurrentSelection: Bool {
        guard let currentContext = currentPrintContext() else {
            return false
        }
        return startedPrintContext == currentContext
    }

    var needsSlicing: Bool {
        if let parsedInfo {
            return !parsedInfo.hasGcode
        }
        return false
    }

    var projectDefaultMachineName: String {
        guard let parsedInfo, !parsedInfo.printer.printerSettingsId.isEmpty else {
            return "Unknown"
        }
        return readableProfileName(
            settingOrName: parsedInfo.printer.printerSettingsId,
            profiles: allSlicerMachines
        )
    }

    var projectDefaultProcessName: String {
        guard let parsedInfo, !parsedInfo.printProfile.printSettingsId.isEmpty else {
            return "Unknown"
        }
        return readableProfileName(
            settingOrName: parsedInfo.printProfile.printSettingsId,
            profiles: allSlicerProcesses
        )
    }

    func refreshPrinters() async {
        guard !gatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isLoading else { return }

        do {
            let fetchedPrinters = try await gatewayClient().fetchPrinters()
            await handlePolledTransitions(newStatuses: fetchedPrinters)
            printers = fetchedPrinters
        } catch {
            // Silently ignore periodic refresh failures
        }
    }

    func refreshAll() async {
        guard !gatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setMessage("Set the gateway server address first.", .info)
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let fetchedPrinters = try await gatewayClient().fetchPrinters()
            await handlePolledTransitions(newStatuses: fetchedPrinters)
            printers = fetchedPrinters
            applyPrinterSelectionAfterRefresh()
        } catch {
            setMessage(error.localizedDescription, .error)
            return
        }

        await loadSetupData()
        if selectedFile != nil && parsedInfo == nil {
            await parseSelectedFile()
        }
    }

    func onGatewayAddressSaved() async {
        persistSettings()
        await refreshAll()
    }

    func onPrinterChanged(_ printerId: String) async {
        selectedPrinterId = printerId
        persistedSettings.selectedPrinterId = printerId
        persistSettings()
        await loadSetupData()
        applyPersistedProfileSelections()
        applyFilamentMappingFromCurrentData()
    }

    func import3MF(from url: URL) async {
        do {
            let file = try loadFile(url: url)
            startedPrintContext = nil
            selectedFile = file
            await parseSelectedFile()
        } catch {
            setMessage(error.localizedDescription, .error)
        }
    }

    func importDownloaded3MF(fileName: String, data: Data) async {
        startedPrintContext = nil
        selectedFile = Imported3MFFile(fileName: fileName, data: data)
        await parseSelectedFile()
    }

    private static let defaultMakerWorldURL = URL(string: "https://makerworld.com")!

    func openMakerWorldBrowser(url: URL? = nil) {
        makerWorldBrowserURL = url ?? Self.defaultMakerWorldURL
        isShowingMakerWorldBrowser = true
        selectedTab = 1
    }

    func clearFile() {
        uploadPollingTask?.cancel()
        uploadProgress = nil
        activeUploadId = nil
        isCancellingUpload = false
        startedPrintContext = nil
        selectedFile = nil
        parsedInfo = nil
        filamentMatchesByIndex = [:]
        machineOptions = []
        processOptions = []
        plateTypeOptions = Self.defaultPlateTypeOptions
        selectedMachineProfileId = ""
        selectedProcessProfileId = ""
        selectedPlateType = ""
        selectedPlateId = 0
        filamentTrayByIndex = [:]
    }

    func trayProfileSelection(for slot: Int) -> String {
        trayProfileBySlot[slot] ?? ""
    }

    func setTrayProfileSelection(slot: Int, settingId: String) {
        trayProfileBySlot[slot] = settingId
        updatePerPrinterSelection { selection in
            selection.trayProfileBySlot[slot] = settingId
        }
    }

    func filamentTraySelection(for filamentIndex: Int) -> Int? {
        filamentTrayByIndex[filamentIndex]
    }

    func setFilamentTraySelection(index: Int, slot: Int?) {
        if let slot {
            filamentTrayByIndex[index] = slot
        } else {
            filamentTrayByIndex.removeValue(forKey: index)
        }
        updatePerPrinterSelection { selection in
            if let slot {
                selection.filamentTrayByIndex[index] = slot
            } else {
                selection.filamentTrayByIndex.removeValue(forKey: index)
            }
        }
    }

    func setMachineProfile(_ id: String) {
        selectedMachineProfileId = id
        updatePerPrinterSelection { $0.machineProfileId = id }
    }

    func setProcessProfile(_ id: String) {
        selectedProcessProfileId = id
        updatePerPrinterSelection { $0.processProfileId = id }
    }

    func setPlateType(_ id: String) {
        selectedPlateType = id
        updatePerPrinterSelection { $0.plateType = id }
    }

    func submitPrint() async {
        guard let submission = buildSubmission() else { return }
        let printContext = printContext(for: submission)
        let needsSlicing = !(parsedInfo?.hasGcode ?? true)

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let response: PrintResponse
            if needsSlicing {
                // Slice with progress, then trigger print from the resulting job.
                let jobId = try await runSliceJob(submission, kind: "print")
                currentJobId = jobId
                response = try await gatewayClient().printFromJob(
                    jobId: jobId,
                    printerId: submission.printerId
                )
                currentJobId = nil
                clearPendingSliceJob()
            } else {
                response = try await gatewayClient().submitPrint(submission)
            }
            handlePrintResponse(response, startedContext: printContext)
            lastPrintEstimate = response.estimate
            let resolvedPrinterId = response.printerId.isEmpty ? printContext.printerId : response.printerId
            lastPrintPrinterName = printerName(for: resolvedPrinterId)
            showPrintSuccessModal = true
        } catch let error as URLError where error.code == .cancelled {
            // user-initiated cancel — silent
        } catch {
            setMessage(error.localizedDescription, .error)
        }
    }

    func submitPreview() async {
        guard let selectedFile, let parsedInfo else {
            setMessage("Select a 3MF file first.", .error)
            return
        }
        let preferredPlateId = parsedInfo.plates.count > 1 ? selectedPlateId : nil

        isLoadingPreview = true
        defer { isLoadingPreview = false }

        do {
            if parsedInfo.hasGcode {
                // Already sliced — extract gcode locally
                let fileData = selectedFile.data
                let scene = try await Task.detached {
                    let reader = ThreeMFReader()
                    let extracted = try reader.extractGCode(
                        from: fileData,
                        preferredPlateId: preferredPlateId
                    )
                    let parser = GCodeParser()
                    let model = try parser.parse(extracted.content)
                    return PrintSceneBuilder().buildScene(from: model)
                }.value

                previewScene = scene
                currentJobId = nil
                isShowingPreview = true
                setMessage("", .info)
            } else {
                // Needs slicing — submit a slice job and poll for progress.
                guard let submission = buildSubmission() else { return }
                let jobId = try await runSliceJob(submission, kind: "preview")
                let previewResult = try await gatewayClient().fetchSliceJobOutput(
                    jobId: jobId,
                    fallbackFileName: submission.file.fileName
                )

                let threeMFData = previewResult.threeMFData
                let scene = try await Task.detached {
                    let reader = ThreeMFReader()
                    let extracted = try reader.extractGCode(
                        from: threeMFData,
                        preferredPlateId: preferredPlateId
                    )
                    let parser = GCodeParser()
                    let model = try parser.parse(extracted.content)
                    return PrintSceneBuilder().buildScene(from: model)
                }.value

                previewScene = scene
                currentJobId = jobId
                previewEstimate = previewResult.estimate
                isShowingPreview = true
                clearPendingSliceJob()
                setMessage("", .info)
            }
        } catch let error as URLError where error.code == .cancelled {
            // user-initiated cancel — silent
        } catch {
            setMessage(error.localizedDescription, .error)
        }
    }

    func confirmPreviewPrint() async {
        let startedContext = currentPrintContext()
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            if let jobId = currentJobId {
                // Was sliced via the slice-job flow — use the job id
                let response = try await gatewayClient().printFromJob(
                    jobId: jobId,
                    printerId: resolvedPrinterId()
                )
                dismissPreview()
                handlePrintResponse(response, startedContext: startedContext)
            } else {
                // Already sliced — use regular print
                guard let submission = buildSubmission() else { return }
                let response = try await gatewayClient().submitPrint(submission)
                dismissPreview()
                handlePrintResponse(response, startedContext: startedContext ?? printContext(for: submission))
            }
        } catch let error as URLError where error.code == .cancelled {
            // user-initiated cancel — silent
        } catch {
            setMessage(error.localizedDescription, .error)
        }
    }

    func cancelPreview() {
        transferService.cancelAll()
        // Best-effort: tell the gateway to cancel any in-flight job we kicked off.
        if let jobId = currentJobId {
            Task { [client = gatewayClient()] in
                try? await client.cancelSliceJob(jobId: jobId)
            }
        }
        dismissPreview()
    }

    /// Submit a slice job and poll until terminal, surfacing progress to the UI.
    /// Returns the job id on success; throws on failure/cancellation.
    /// `kind` is persisted alongside the job id so a kill-and-relaunch can resume.
    private func runSliceJob(_ submission: PrintSubmission, kind: String) async throws -> String {
        slicingProgress = 0
        slicingPhase = nil
        defer {
            slicingProgress = nil
            slicingPhase = nil
        }

        let client = gatewayClient()
        let jobId = try await client.createSliceJob(submission)
        savePendingSliceJob(jobId: jobId, kind: kind)

        do {
            return try await pollUntilReady(jobId: jobId, client: client)
        } catch {
            clearPendingSliceJob()
            throw error
        }
    }

    /// Poll a job until it leaves the queued/slicing/uploading states.
    /// Returns the job id on `ready`/`printing`; throws on `failed` or `cancelled`.
    private func pollUntilReady(
        jobId: String,
        client: GatewayClient
    ) async throws -> String {
        while true {
            try Task.checkCancellation()
            let job = try await client.fetchSliceJob(jobId: jobId)
            slicingProgress = job.progress
            slicingPhase = job.phase
            if job.isTerminal {
                switch job.status {
                case "ready":
                    return jobId
                case "failed":
                    clearPendingSliceJob()
                    throw GatewayClientError.serverError(
                        job.error ?? "Slicing failed"
                    )
                case "cancelled":
                    clearPendingSliceJob()
                    throw URLError(.cancelled)
                case "printing":
                    // Shouldn't happen with auto_print=false, but treat as success.
                    return jobId
                default:
                    clearPendingSliceJob()
                    throw GatewayClientError.serverError(
                        "Unexpected slice job state: \(job.status)"
                    )
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    func dismissPrintSuccessModal() {
        showPrintSuccessModal = false
        lastPrintEstimate = nil
        lastPrintPrinterName = nil
    }

    func pausePrint() async {
        guard let printerId = selectedPrinter?.id else { return }
        do {
            try await gatewayClient().pausePrint(printerId: printerId)
            await refreshPrinters()
        } catch {
            setMessage(error.localizedDescription, .error)
        }
    }

    func resumePrint() async {
        guard let printerId = selectedPrinter?.id else { return }
        do {
            try await gatewayClient().resumePrint(printerId: printerId)
            await refreshPrinters()
        } catch {
            setMessage(error.localizedDescription, .error)
        }
    }

    func cancelPrint() async {
        guard let printerId = selectedPrinter?.id else { return }
        do {
            try await gatewayClient().cancelPrint(printerId: printerId)
            await refreshPrinters()
        } catch {
            setMessage(error.localizedDescription, .error)
        }
    }

    func setSpeed(_ level: SpeedLevel) async {
        guard let printerId = selectedPrinter?.id else { return }
        isSpeedChangeInFlight = true
        defer { isSpeedChangeInFlight = false }
        do {
            try await gatewayClient().setSpeed(printerId: printerId, level: level)
            await refreshPrinters()
        } catch {
            setMessage(error.localizedDescription, .error)
        }
    }

    func setChamberLight(on: Bool) async {
        guard let printer = selectedPrinter else { return }
        // Flip the UI immediately. The MQTT `lights_report` can take a couple
        // of seconds to round-trip; waiting for `refreshPrinters()` before
        // updating the button makes the tap feel unresponsive.
        optimisticChamberLightOn = on
        chamberLightPending = true
        do {
            try await gatewayClient().setLight(printerId: printer.id, on: on)
            chamberLightPending = false
            // Poll the gateway a few times in the background — keep the
            // optimistic value visible until the server reports the same
            // thing, then drop it. Bounded so a dropped MQTT report can't
            // pin the button forever.
            Task { [weak self] in
                for _ in 0 ..< 6 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await self?.refreshPrinters()
                    if self?.selectedPrinter?.camera?.chamberLight?.on == on {
                        self?.optimisticChamberLightOn = nil
                        return
                    }
                }
                // Server never confirmed — release the override anyway so a
                // future (correct) report isn't shadowed.
                self?.optimisticChamberLightOn = nil
            }
        } catch {
            optimisticChamberLightOn = nil
            chamberLightPending = false
            setMessage(error.localizedDescription, .error)
        }
    }

    private func dismissPreview() {
        isShowingPreview = false
        previewScene = nil
        currentJobId = nil
        previewEstimate = nil
        clearPendingSliceJob()
    }

    // MARK: - Pending slice job persistence

    private func savePendingSliceJob(jobId: String, kind: String) {
        let memento = PendingSliceJob(jobId: jobId, kind: kind)
        if let data = try? JSONEncoder().encode(memento) {
            UserDefaults.standard.set(data, forKey: Self.pendingSliceJobKey)
        }
    }

    private func clearPendingSliceJob() {
        UserDefaults.standard.removeObject(forKey: Self.pendingSliceJobKey)
    }

    private func loadPendingSliceJob() -> PendingSliceJob? {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingSliceJobKey),
              let memento = try? JSONDecoder().decode(PendingSliceJob.self, from: data)
        else {
            return nil
        }
        return memento
    }

    /// Resume a slice job persisted from a prior session, if any.
    /// Called from app launch. Polls the gateway for the saved job; once it
    /// reaches `ready`, surfaces the appropriate UI (preview modal or print).
    func resumePersistedSliceJob() async {
        guard let memento = loadPendingSliceJob() else { return }
        let client = gatewayClient()

        // First fetch — if the job no longer exists on the gateway, drop the memento.
        let initial: SliceJobStatusResponse
        do {
            initial = try await client.fetchSliceJob(jobId: memento.jobId)
        } catch {
            clearPendingSliceJob()
            return
        }

        // If already terminal and not `ready`, just clear and surface any error.
        if initial.isTerminal {
            switch initial.status {
            case "failed":
                setMessage(initial.error ?? "Slicing failed", .error)
                clearPendingSliceJob()
                return
            case "cancelled":
                clearPendingSliceJob()
                return
            case "printing":
                clearPendingSliceJob()
                return
            case "ready":
                break  // fall through to consume
            default:
                clearPendingSliceJob()
                return
            }
        }

        // Show progress UI while we wait for terminal.
        switch memento.kind {
        case "preview":
            isLoadingPreview = true
        default:
            isSubmitting = true
        }
        slicingProgress = initial.progress
        slicingPhase = initial.phase

        defer {
            isLoadingPreview = false
            isSubmitting = false
            slicingProgress = nil
            slicingPhase = nil
        }

        do {
            let jobId: String
            if initial.status == "ready" {
                jobId = memento.jobId
            } else {
                jobId = try await pollUntilReady(jobId: memento.jobId, client: client)
            }
            try await consumeReadyJob(jobId: jobId, kind: memento.kind, client: client)
        } catch let error as URLError where error.code == .cancelled {
            clearPendingSliceJob()
        } catch {
            setMessage(error.localizedDescription, .error)
        }
    }

    /// Once a job is `ready`, either render its preview or trigger the print,
    /// based on the original intent stored alongside the job id.
    private func consumeReadyJob(
        jobId: String, kind: String, client: GatewayClient
    ) async throws {
        switch kind {
        case "preview":
            let result = try await client.fetchSliceJobOutput(
                jobId: jobId,
                fallbackFileName: "preview.3mf"
            )
            let threeMFData = result.threeMFData
            let scene = try await Task.detached {
                let reader = ThreeMFReader()
                let extracted = try reader.extractGCode(
                    from: threeMFData,
                    preferredPlateId: nil
                )
                let parser = GCodeParser()
                let model = try parser.parse(extracted.content)
                return PrintSceneBuilder().buildScene(from: model)
            }.value
            previewScene = scene
            currentJobId = jobId
            previewEstimate = result.estimate
            isShowingPreview = true
            clearPendingSliceJob()
        default:
            // print kind — fetch the job to learn the printer it was bound to,
            // then trigger the print.
            let job = try await client.fetchSliceJob(jobId: jobId)
            let printerId = (job.printerId?.isEmpty == false ? job.printerId! : resolvedPrinterId())
            let response = try await client.printFromJob(jobId: jobId, printerId: printerId)
            handlePrintResponse(response, startedContext: nil)
            lastPrintEstimate = response.estimate
            let resolvedId = response.printerId.isEmpty ? printerId : response.printerId
            lastPrintPrinterName = printerName(for: resolvedId)
            showPrintSuccessModal = true
            clearPendingSliceJob()
        }
    }

    private func buildSubmission() -> PrintSubmission? {
        guard let selectedFile, let parsedInfo else {
            setMessage("Select a 3MF file first.", .error)
            return nil
        }

        if needsSlicing && (selectedMachineProfileId.isEmpty || selectedProcessProfileId.isEmpty) {
            setMessage("This file needs slicing. Select machine and process profiles.", .error)
            return nil
        }

        let plateIdToSend: Int? = parsedInfo.plates.count > 1 ? selectedPlateId : nil

        return PrintSubmission(
            file: selectedFile,
            printerId: resolvedPrinterId(),
            plateId: plateIdToSend,
            plateType: selectedPlateType,
            machineProfile: selectedMachineProfileId,
            processProfile: selectedProcessProfileId,
            filamentOverrides: buildFilamentOverrides(for: parsedInfo)
        )
    }

    private func resolvedPrinterId() -> String {
        if !selectedPrinterId.isEmpty {
            return selectedPrinterId
        }
        if printers.count == 1 {
            return printers[0].id
        }
        return ""
    }

    private func handlePrintResponse(_ response: PrintResponse, startedContext: StartedPrintContext?) {
        startedPrintContext = startedContext
        var output = "Print started: \(response.fileName)"
        if response.wasSliced {
            output += " (sliced)"
        }
        let transfer = settingsTransferMessage(response.settingsTransfer)
        if !transfer.isEmpty {
            output += "\n\(transfer)"
        }
        let level: MessageLevel = hasDiscardedFilamentCustomizations(response.settingsTransfer) ? .warning : .success
        setMessage(output, level)

        if let uploadId = response.uploadId {
            startUploadPolling(uploadId: uploadId)
        }

        let printerId = response.printerId.isEmpty ? (startedContext?.printerId ?? "") : response.printerId
        if !printerId.isEmpty {
            let fileName = response.fileName.isEmpty ? (startedContext?.fileName ?? "Print") : response.fileName
            let displayName = printerName(for: printerId)
            Task { [weak self] in
                await self?.liveActivityService.startActivity(
                    printerId: printerId,
                    printerName: displayName,
                    fileName: fileName,
                    thumbnail: nil,
                    initialState: PrintActivityAttributes.ContentState(
                        state: .preparing,
                        stageName: "Starting print",
                        progress: 0.0,
                        remainingMinutes: 0,
                        currentLayer: 0,
                        totalLayers: 0,
                        updatedAt: Date()
                    )
                )
            }
        }
    }

    private func printerName(for printerId: String) -> String {
        if let match = printers.first(where: { $0.id == printerId }) {
            return match.name
        }
        return printerId
    }

    private static let activeStateKeys: Set<String> = ["preparing", "printing", "paused"]

    private func handlePolledTransitions(newStatuses: [PrinterStatus]) async {
        for status in newStatuses {
            let stateKey = status.state.lowercased()
            let prev = previousStates[status.id]
            previousStates[status.id] = stateKey

            let content = makeContentState(from: status)
            let wasActive = prev.map(Self.activeStateKeys.contains) ?? false
            let isActive = Self.activeStateKeys.contains(stateKey)

            if isActive && !liveActivityService.hasActivity(for: status.id) {
                await liveActivityService.startActivity(
                    printerId: status.id,
                    printerName: status.name,
                    fileName: status.job?.fileName ?? "",
                    thumbnail: nil,
                    initialState: content
                )
            }

            guard let prev else { continue }
            if prev == stateKey { continue }

            switch stateKey {
            case "printing":
                if prev == "paused" {
                    await liveActivityService.updateActivity(printerId: status.id, state: content)
                }
            case "paused":
                await liveActivityService.updateActivity(printerId: status.id, state: content)
                if !pushService.capabilitiesEnabled {
                    await notificationService.fireLocal(
                        title: "Print paused",
                        body: "\(status.name) paused",
                        identifier: "\(status.id)-paused"
                    )
                }
            case "error":
                await liveActivityService.endActivity(
                    printerId: status.id,
                    finalState: content,
                    dismissalPolicy: .immediate
                )
                if !pushService.capabilitiesEnabled {
                    await notificationService.fireLocal(
                        title: "Print failed",
                        body: "\(status.name) stopped with an error",
                        identifier: "\(status.id)-error"
                    )
                }
            case "finished":
                await liveActivityService.endActivity(
                    printerId: status.id,
                    finalState: content,
                    dismissalPolicy: .after(Date().addingTimeInterval(4 * 3600))
                )
            case "cancelled":
                await liveActivityService.endActivity(
                    printerId: status.id,
                    finalState: content,
                    dismissalPolicy: .immediate
                )
            default:
                break
            }
        }
    }

    private func makeContentState(from status: PrinterStatus) -> PrintActivityAttributes.ContentState {
        let progress = Double(status.job?.progress ?? 0) / 100.0
        return PrintActivityAttributes.ContentState(
            state: badge(for: status.state),
            stageName: status.stageName,
            progress: progress,
            remainingMinutes: status.job?.remainingMinutes ?? 0,
            currentLayer: status.job?.currentLayer ?? 0,
            totalLayers: status.job?.totalLayers ?? 0,
            updatedAt: Date()
        )
    }

    private func badge(for state: String) -> PrinterStateBadge {
        switch state.lowercased() {
        case "idle": return .idle
        case "preparing": return .preparing
        case "printing", "running": return .printing
        case "paused": return .paused
        case "finished": return .finished
        case "cancelled": return .cancelled
        case "error": return .error
        case "offline": return .offline
        default: return .idle
        }
    }

    private func startUploadPolling(uploadId: String) {
        uploadPollingTask?.cancel()
        activeUploadId = uploadId
        uploadProgress = 0

        uploadPollingTask = Task {
            repeat {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                do {
                    let state = try await gatewayClient().fetchUploadProgress(uploadId: uploadId)
                    uploadProgress = state.progress
                    if state.status == "completed" {
                        finishUploadPolling()
                        return
                    }
                    if state.status == "cancelled" {
                        finishUploadPolling()
                        startedPrintContext = nil
                        setMessage("Upload cancelled.", .info)
                        return
                    }
                    if state.status == "failed" {
                        finishUploadPolling()
                        setMessage(state.error ?? "Upload failed.", .error)
                        return
                    }
                } catch {
                    // ignore transient network errors
                }
            } while !Task.isCancelled
        }
    }

    private func finishUploadPolling() {
        uploadProgress = nil
        activeUploadId = nil
        isCancellingUpload = false
    }

    func cancelUpload() async {
        guard let uploadId = activeUploadId, !isCancellingUpload else { return }
        isCancellingUpload = true
        do {
            try await gatewayClient().cancelUpload(uploadId: uploadId)
        } catch {
            isCancellingUpload = false
            setMessage(error.localizedDescription, .error)
        }
    }

    private func currentPrintContext() -> StartedPrintContext? {
        guard let selectedFile, let parsedInfo else {
            return nil
        }

        let plateIdToSend: Int? = parsedInfo.plates.count > 1 ? selectedPlateId : nil

        return StartedPrintContext(
            printerId: resolvedPrinterId(),
            fileName: selectedFile.fileName,
            fileSize: selectedFile.data.count,
            plateId: plateIdToSend,
            plateType: selectedPlateType,
            machineProfile: selectedMachineProfileId,
            processProfile: selectedProcessProfileId,
            filamentOverrides: buildFilamentOverrides(for: parsedInfo)
        )
    }

    private func printContext(for submission: PrintSubmission) -> StartedPrintContext {
        StartedPrintContext(
            printerId: submission.printerId,
            fileName: submission.file.fileName,
            fileSize: submission.file.data.count,
            plateId: submission.plateId,
            plateType: submission.plateType,
            machineProfile: submission.machineProfile,
            processProfile: submission.processProfile,
            filamentOverrides: submission.filamentOverrides
        )
    }

    private func parseSelectedFile() async {
        guard let selectedFile else {
            return
        }

        isParsing = true
        defer { isParsing = false }

        parsedInfo = nil
        machineOptions = []
        processOptions = []
        plateTypeOptions = Self.defaultPlateTypeOptions
        selectedMachineProfileId = ""
        selectedProcessProfileId = ""
        selectedPlateType = ""
        selectedPlateId = 0
        filamentMatchesByIndex = [:]
        filamentTrayByIndex = [:]

        do {
            var info = try await gatewayClient().parse3MF(file: selectedFile)
            info.filaments = trimUnusedFilaments(
                declared: info.filaments,
                fileData: selectedFile.data,
                plate: info.plates.first?.id ?? 1,
                hasGcode: info.hasGcode
            )
            parsedInfo = info
            selectedPlateId = info.plates.first?.id ?? 0
            configureProfileOptions(for: info)
            await refreshFilamentMatches()
            applyFilamentMappingFromCurrentData()

            if info.hasGcode {
                setMessage("File parsed: already sliced.", .success)
            } else {
                setMessage("File parsed: slicing required.", .info)
            }
        } catch {
            setMessage(error.localizedDescription, .error)
        }
    }

    private func loadSetupData() async {
        let machineFilter = selectedMachineFilterId()

        async let amsResult = fetchAMSGracefully()
        async let machinesResult = fetchMachinesGracefully()
        async let plateTypesResult = fetchPlateTypesGracefully()

        let fetchedAMS = await amsResult
        let fetchedAllMachines = await machinesResult
        allSlicerMachines = fetchedAllMachines
        slicerMachines = filterMachinesForSelectedPrinter(allMachines: fetchedAllMachines, machineFilter: machineFilter)
        plateTypeOptions = buildPlateTypeOptions(await plateTypesResult)

        async let processesResult = fetchProcessesGracefully(machine: machineFilter)
        async let filamentsResult = fetchFilamentsGracefully(machine: machineFilter)
        async let allProcessesResult = machineFilter.isEmpty
            ? fetchProcessesGracefully(machine: machineFilter)
            : fetchProcessesGracefully(machine: "")
        async let allFilamentsResult = machineFilter.isEmpty
            ? fetchFilamentsGracefully(machine: machineFilter)
            : fetchFilamentsGracefully(machine: "")

        slicerProcesses = await processesResult
        slicerFilaments = await filamentsResult
        amsAssignableFilaments = slicerFilaments.filter { $0.amsAssignable == true }
        allSlicerProcesses = await allProcessesResult
        allSlicerFilaments = await allFilamentsResult

        applyAMSData(fetchedAMS)
        applyPersistedProfileSelections()
        await refreshFilamentMatches()
        applyFilamentMappingFromCurrentData()
    }

    private func applyPrinterSelectionAfterRefresh() {
        if printers.count == 1 {
            selectedPrinterId = printers[0].id
        } else if !selectedPrinterId.isEmpty,
                  !printers.contains(where: { $0.id == selectedPrinterId }) {
            selectedPrinterId = ""
        }

        if selectedPrinterId.isEmpty,
           !persistedSettings.selectedPrinterId.isEmpty,
           printers.contains(where: { $0.id == persistedSettings.selectedPrinterId }) {
            selectedPrinterId = persistedSettings.selectedPrinterId
        }

        persistedSettings.selectedPrinterId = selectedPrinterId
        persistSettings()
    }

    private func selectedMachineFilterId() -> String {
        if !selectedPrinterId.isEmpty,
           let selected = printers.first(where: { $0.id == selectedPrinterId }) {
            return selected.machineModel
        }
        return printers.first?.machineModel ?? ""
    }

    private func filterMachinesForSelectedPrinter(allMachines: [SlicerProfile], machineFilter: String) -> [SlicerProfile] {
        guard !machineFilter.isEmpty,
              let current = allMachines.first(where: { $0.settingId == machineFilter }),
              let printerModel = current.printerModel,
              !printerModel.isEmpty else {
            return allMachines
        }

        return allMachines.filter { $0.printerModel == printerModel }
    }

    private func applyAMSData(_ amsResponse: AMSResponse?) {
        guard let amsResponse else {
            amsTrays = []
            amsUnits = []
            vtTray = nil
            trayProfileBySlot = [:]
            return
        }

        amsUnits = amsResponse.units.sorted { $0.id < $1.id }
        vtTray = amsResponse.vtTray
        amsTrays = amsResponse.trays.sorted { $0.slot < $1.slot }

        var allTrays = amsTrays
        if let vt = vtTray {
            allTrays.append(vt)
        }

        var selections: [Int: String] = [:]
        let persisted = perPrinterSelection()
        let validIds = Set(amsAssignableFilaments.map { $0.settingId })

        for tray in allTrays {
            if let persistedId = persisted.trayProfileBySlot[tray.slot],
               persistedId.isEmpty || validIds.contains(persistedId) {
                selections[tray.slot] = persistedId
            } else if let matched = tray.matchedFilament?.settingId,
                      validIds.contains(matched) {
                selections[tray.slot] = matched
            } else {
                selections[tray.slot] = ""
            }
        }

        trayProfileBySlot = selections
    }

    private func configureProfileOptions(for info: ThreeMFInfo) {
        let machineBuild = buildProfileOptions(
            filtered: slicerMachines,
            fileSettingOrName: info.printer.printerSettingsId,
            allProfiles: allSlicerMachines
        )
        machineOptions = machineBuild.options

        let processBuild = buildProfileOptions(
            filtered: slicerProcesses,
            fileSettingOrName: info.printProfile.printSettingsId,
            allProfiles: allSlicerProcesses
        )
        processOptions = processBuild.options

        let persisted = perPrinterSelection()

        let validMachineIds = Set(machineBuild.options.map { $0.id }.filter { !$0.isEmpty })
        if validMachineIds.contains(persisted.machineProfileId) {
            selectedMachineProfileId = persisted.machineProfileId
        } else {
            selectedMachineProfileId = machineBuild.defaultSelection
        }

        let validProcessIds = Set(processBuild.options.map { $0.id }.filter { !$0.isEmpty })
        if validProcessIds.contains(persisted.processProfileId) {
            selectedProcessProfileId = persisted.processProfileId
        } else {
            selectedProcessProfileId = processBuild.defaultSelection
        }

        applyPersistedPlateTypeSelection()
    }

    private func applyPersistedProfileSelections() {
        let persisted = perPrinterSelection()

        let validMachineIds = Set(machineOptions.map { $0.id })
        if validMachineIds.contains(persisted.machineProfileId) {
            selectedMachineProfileId = persisted.machineProfileId
        }

        let validProcessIds = Set(processOptions.map { $0.id })
        if validProcessIds.contains(persisted.processProfileId) {
            selectedProcessProfileId = persisted.processProfileId
        }

        applyPersistedPlateTypeSelection()
    }

    /// All available tray slots including the external spool holder.
    var allAvailableTrays: [AMSTray] {
        var trays = amsTrays
        if let vt = vtTray {
            trays.append(vt)
        }
        return trays
    }

    private func applyFilamentMappingFromCurrentData() {
        guard let parsedInfo else {
            filamentTrayByIndex = [:]
            return
        }

        let persisted = perPrinterSelection()
        let validSlots = Set(allAvailableTrays.map { $0.slot })

        var mapping: [Int: Int] = [:]

        for filament in parsedInfo.filaments {
            if let persistedSlot = persisted.filamentTrayByIndex[filament.index], validSlots.contains(persistedSlot) {
                mapping[filament.index] = persistedSlot
                continue
            }

            if let preferredSlot = filamentMatchesByIndex[filament.index]?.preferredTraySlot,
               validSlots.contains(preferredSlot) {
                mapping[filament.index] = preferredSlot
                continue
            }

            let projectFilamentId = projectFilamentId(for: filament).uppercased()
            if !projectFilamentId.isEmpty,
               let exactMatch = allAvailableTrays.first(where: {
                   !$0.filamentId.isEmpty && $0.filamentId.uppercased() == projectFilamentId
               }) {
                mapping[filament.index] = exactMatch.slot
                continue
            }

            let wantedType = filament.type.uppercased()
            if let match = allAvailableTrays.first(where: {
                !$0.trayType.isEmpty && $0.trayType.uppercased() == wantedType
            }) {
                mapping[filament.index] = match.slot
            }
        }

        filamentTrayByIndex = mapping
    }

    private func refreshFilamentMatches() async {
        guard let parsedInfo, !parsedInfo.hasGcode else {
            filamentMatchesByIndex = [:]
            return
        }

        do {
            let response = try await gatewayClient().fetchFilamentMatches(
                printerId: resolvedPrinterId(),
                filaments: parsedInfo.filaments
            )
            filamentMatchesByIndex = Dictionary(
                uniqueKeysWithValues: response.matches.map { ($0.index, $0) }
            )
        } catch {
            filamentMatchesByIndex = [:]
        }
    }

    private func buildProfileOptions(
        filtered: [SlicerProfile],
        fileSettingOrName: String,
        allProfiles: [SlicerProfile]
    ) -> (options: [ProfileOption], defaultSelection: String) {
        var options: [ProfileOption] = [ProfileOption(id: "", label: "Select...")]
        var defaultSelection = ""

        func isMatch(_ profile: SlicerProfile, _ value: String) -> Bool {
            profile.settingId == value || profile.name == value
        }

        let inFiltered = fileSettingOrName.isEmpty
            ? nil
            : filtered.first(where: { isMatch($0, fileSettingOrName) })
        let inAll = fileSettingOrName.isEmpty || inFiltered != nil
            ? nil
            : allProfiles.first(where: { isMatch($0, fileSettingOrName) })

        if !fileSettingOrName.isEmpty, inFiltered == nil {
            if let inAll {
                options.append(
                    ProfileOption(
                        id: inAll.settingId,
                        label: "\(inAll.name) (from file - different printer)"
                    )
                )
                defaultSelection = inAll.settingId
            } else {
                options.append(
                    ProfileOption(
                        id: fileSettingOrName,
                        label: "\(fileSettingOrName) (from file - unknown)"
                    )
                )
                defaultSelection = fileSettingOrName
            }
        }

        for profile in filtered {
            let label: String
            if let inFiltered, isMatch(profile, fileSettingOrName), profile.settingId == inFiltered.settingId {
                label = "\(profile.name) (from file)"
                defaultSelection = profile.settingId
            } else {
                label = profile.name
            }

            options.append(ProfileOption(id: profile.settingId, label: label))
        }

        return (options, defaultSelection)
    }

    /// Trim filament slots the active plate doesn't reference, so downstream
    /// calls (`/api/print-preview`, `/api/print`) only send overrides for slots
    /// the model actually uses. Passing extra slots has been observed to fail
    /// slicing on multi-filament projects where only one slot is used. The
    /// server (bambu-gateway + orcaslicer-cli) also does its own trim — this
    /// is defense in depth so an older server still works.
    private func trimUnusedFilaments(
        declared: [ProjectFilament],
        fileData: Data,
        plate: Int,
        hasGcode: Bool
    ) -> [ProjectFilament] {
        guard !hasGcode, !declared.isEmpty else {
            return declared
        }
        guard let usedSlots = ThreeMFReader().readUsedFilamentSlots(from: fileData, plate: plate),
              !usedSlots.isEmpty else {
            return declared
        }
        let filtered = declared.filter { usedSlots.contains($0.index) }
        if filtered.count < declared.count && !filtered.isEmpty {
            return filtered
        }
        return declared
    }

    private func buildFilamentOverrides(for info: ThreeMFInfo) -> [Int: FilamentOverrideSelection] {
        guard !info.hasGcode else {
            return [:]
        }

        var overrides: [Int: FilamentOverrideSelection] = [:]
        for filament in info.filaments {
            guard let slot = filamentTrayByIndex[filament.index],
                  let settingId = trayProfileBySlot[slot],
                  !settingId.isEmpty else {
                continue
            }
            overrides[filament.index] = FilamentOverrideSelection(
                profileSettingId: settingId,
                traySlot: slot
            )
        }
        return overrides
    }

    private func projectFilamentId(for filament: ProjectFilament) -> String {
        let wanted = filament.settingId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else {
            return ""
        }

        let profiles = slicerFilaments + allSlicerFilaments
        if let profile = profiles.first(where: { $0.settingId == wanted || $0.name == wanted }) {
            return profile.filamentId ?? ""
        }
        return ""
    }

    private func readableProfileName(settingOrName: String, profiles: [SlicerProfile]) -> String {
        if let matched = profiles.first(where: { $0.settingId == settingOrName || $0.name == settingOrName }) {
            return matched.name
        }
        return settingOrName
    }

    private func buildPlateTypeOptions(_ types: [PlateTypeOption]) -> [ProfileOption] {
        let mapped = types.map { ProfileOption(id: $0.value, label: $0.label) }
        let source = mapped.isEmpty ? Array(Self.defaultPlateTypeOptions.dropFirst()) : mapped
        return [ProfileOption(id: "", label: "Use file/default")] + source
    }

    private func applyPersistedPlateTypeSelection() {
        let persisted = perPrinterSelection()
        let validPlateTypes = Set(plateTypeOptions.map { $0.id })
        selectedPlateType = validPlateTypes.contains(persisted.plateType) ? persisted.plateType : ""
    }

    private func settingsTransferMessage(_ transfer: SettingsTransferInfo?) -> String {
        guard let transfer else {
            return ""
        }

        var parts: [String] = []

        if transfer.status == "applied", !transfer.transferred.isEmpty {
            let keys = transfer.transferred.map(\.key).joined(separator: ", ")
            parts.append("Transferred \(transfer.transferred.count) process setting(s): \(keys)")
        }

        for entry in transfer.filaments {
            if entry.status == "applied", !entry.transferred.isEmpty {
                let keys = entry.transferred.map(\.key).joined(separator: ", ")
                parts.append("Filament slot \(entry.slot): applied \(entry.transferred.count) customization(s) (\(keys)).")
            } else if entry.status == "filament_changed", !entry.discarded.isEmpty {
                let discarded = entry.discarded.joined(separator: ", ")
                let original = entry.originalFilament.isEmpty ? "(unknown)" : entry.originalFilament
                let selected = entry.selectedFilament.isEmpty ? "(unknown)" : entry.selectedFilament
                parts.append("Filament slot \(entry.slot): discarded \(entry.discarded.count) customization(s) (\(discarded)) — replaced \(original) with \(selected).")
            }
        }

        return parts.joined(separator: " ")
    }

    private func hasDiscardedFilamentCustomizations(_ transfer: SettingsTransferInfo?) -> Bool {
        guard let transfer else { return false }
        return transfer.filaments.contains { entry in
            entry.status == "filament_changed" && !entry.discarded.isEmpty
        }
    }

    private func perPrinterSelection() -> PerPrinterSelection {
        let key = perPrinterKey()
        return persistedSettings.perPrinter[key] ?? .empty
    }

    private func updatePerPrinterSelection(_ block: (inout PerPrinterSelection) -> Void) {
        let key = perPrinterKey()
        var selection = persistedSettings.perPrinter[key] ?? .empty
        block(&selection)
        persistedSettings.perPrinter[key] = selection
        persistSettings()
    }

    private func perPrinterKey() -> String {
        if !selectedPrinterId.isEmpty {
            return selectedPrinterId
        }
        if let first = printers.first {
            return first.id
        }
        return "default"
    }

    private func persistSettings() {
        persistedSettings.gatewayBaseURL = gatewayBaseURL
        persistedSettings.selectedPrinterId = selectedPrinterId
        settingsStore.save(persistedSettings)
    }

    private func gatewayClient() -> GatewayClient {
        GatewayClient(baseURLString: gatewayBaseURL, transferService: transferService)
    }

    private func loadFile(url: URL) throws -> Imported3MFFile {
        guard url.pathExtension.lowercased() == "3mf" else {
            throw GatewayClientError.serverError("Only .3mf files are supported.")
        }

        let granted = url.startAccessingSecurityScopedResource()
        defer {
            if granted {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        return Imported3MFFile(fileName: url.lastPathComponent, data: data)
    }

    private func setMessage(_ text: String, _ level: MessageLevel) {
        message = text
        messageLevel = level
    }

    private func fetchAMSGracefully() async -> AMSResponse? {
        do {
            return try await gatewayClient().fetchAMS()
        } catch {
            return nil
        }
    }

    private func fetchMachinesGracefully() async -> [SlicerProfile] {
        do {
            return try await gatewayClient().fetchSlicerMachines()
        } catch {
            return []
        }
    }

    private func fetchProcessesGracefully(machine: String) async -> [SlicerProfile] {
        do {
            return try await gatewayClient().fetchSlicerProcesses(machine: machine)
        } catch {
            return []
        }
    }

    private func fetchFilamentsGracefully(machine: String) async -> [SlicerProfile] {
        do {
            return try await gatewayClient().fetchSlicerFilaments(machine: machine)
        } catch {
            return []
        }
    }

    private func fetchPlateTypesGracefully() async -> [PlateTypeOption] {
        do {
            return try await gatewayClient().fetchSlicerPlateTypes()
        } catch {
            return []
        }
    }
}
