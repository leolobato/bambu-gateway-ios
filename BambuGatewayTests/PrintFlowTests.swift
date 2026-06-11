import XCTest
@testable import BambuGateway

@MainActor
final class PrintFlowTests: XCTestCase {
    private func makeUploadState(
        status: String, progress: Double = 0, error: String? = nil
    ) -> UploadProgressResponse {
        UploadProgressResponse(
            uploadId: "u1", status: status, progress: progress,
            bytesSent: Int(progress), totalBytes: 100, error: error
        )
    }

    private func makePrintResponse(uploadId: String?) -> PrintResponse {
        PrintResponse(
            status: uploadId != nil ? "uploading" : "printing",
            fileName: "test.3mf",
            printerId: "",
            wasSliced: false,
            settingsTransfer: nil,
            uploadId: uploadId,
            estimate: nil
        )
    }

    func test_printResponseWithUploadId_entersUploadingState() {
        let vm = AppViewModel.makeForTesting()

        vm.handlePrintResponseForTests(makePrintResponse(uploadId: "u1"))

        XCTAssertEqual(vm.printFlow, .uploading(progress: nil))
        vm.stopUploadPollingForTests()
    }

    func test_printResponseWithoutUploadId_entersSuccessState() {
        let vm = AppViewModel.makeForTesting()

        vm.handlePrintResponseForTests(makePrintResponse(uploadId: nil))

        XCTAssertEqual(vm.printFlow, .success)
    }

    func test_pollProgress_updatesUploadingProgress() {
        let vm = AppViewModel.makeForTesting()
        vm.printFlow = .uploading(progress: nil)

        let terminal = vm.applyUploadPoll(makeUploadState(status: "uploading", progress: 42))

        XCTAssertFalse(terminal)
        XCTAssertEqual(vm.printFlow, .uploading(progress: 42))
        XCTAssertEqual(vm.uploadProgress, 42)
    }

    func test_pollCompleted_flipsToSuccess() {
        let vm = AppViewModel.makeForTesting()
        vm.printFlow = .uploading(progress: 80)

        let terminal = vm.applyUploadPoll(makeUploadState(status: "completed", progress: 100))

        XCTAssertTrue(terminal)
        XCTAssertEqual(vm.printFlow, .success)
    }

    func test_pollFailed_flipsToFailedWithMessage() {
        let vm = AppViewModel.makeForTesting()
        vm.printFlow = .uploading(progress: 50)

        let terminal = vm.applyUploadPoll(makeUploadState(status: "failed", progress: 50, error: "boom"))

        XCTAssertTrue(terminal)
        XCTAssertEqual(vm.printFlow, .failed("boom"))
    }

    func test_pollCancelled_dismissesFlow() {
        let vm = AppViewModel.makeForTesting()
        vm.printFlow = .uploading(progress: 50)

        let terminal = vm.applyUploadPoll(makeUploadState(status: "cancelled", progress: 50))

        XCTAssertTrue(terminal)
        XCTAssertNil(vm.printFlow)
    }

    func test_pollCompletedAfterDismiss_staysDismissed() {
        let vm = AppViewModel.makeForTesting()
        vm.printFlow = nil  // user dismissed the modal mid-upload

        let terminal = vm.applyUploadPoll(makeUploadState(status: "completed", progress: 100))

        XCTAssertTrue(terminal)
        XCTAssertNil(vm.printFlow)
    }

    func test_secondPrintWhileUploading_resetsToFreshUploading() {
        let vm = AppViewModel.makeForTesting()
        vm.handlePrintResponseForTests(makePrintResponse(uploadId: "u1"))
        vm.applyUploadPoll(makeUploadState(status: "uploading", progress: 42))

        vm.handlePrintResponseForTests(makePrintResponse(uploadId: "u2"))

        XCTAssertEqual(vm.printFlow, .uploading(progress: nil))
        vm.stopUploadPollingForTests()
    }

    func test_pollFailedAfterDismiss_staysDismissedButSetsErrorMessage() {
        let vm = AppViewModel.makeForTesting()
        vm.printFlow = nil  // user dismissed the modal mid-upload

        let terminal = vm.applyUploadPoll(makeUploadState(status: "failed", progress: 50, error: "boom"))

        XCTAssertTrue(terminal)
        XCTAssertNil(vm.printFlow)
        XCTAssertTrue(vm.message.contains("boom"))
    }

    func test_cloudPrintWhileUploading_cancelsStalePollingAndShowsSuccess() {
        let vm = AppViewModel.makeForTesting()
        vm.handlePrintResponseForTests(makePrintResponse(uploadId: "u1"))

        vm.handlePrintResponseForTests(makePrintResponse(uploadId: nil))

        XCTAssertEqual(vm.printFlow, .success)
        XCTAssertNil(vm.uploadProgress)
        vm.stopUploadPollingForTests()  // defensive — polling should already be cancelled
    }

    func test_dismissPrintFlow_clearsEstimateAndPrinterName() {
        let vm = AppViewModel.makeForTesting()
        vm.printFlow = .success
        vm.lastPrintEstimate = PrintEstimate(
            totalFilamentMillimeters: nil,
            totalFilamentGrams: nil,
            modelFilamentMillimeters: nil,
            modelFilamentGrams: nil,
            prepareSeconds: nil,
            modelPrintSeconds: nil,
            totalSeconds: 3600
        )
        vm.lastPrintPrinterName = "X1C"

        vm.dismissPrintFlow()

        XCTAssertNil(vm.printFlow)
        XCTAssertNil(vm.lastPrintEstimate)
        XCTAssertNil(vm.lastPrintPrinterName)
    }
}
