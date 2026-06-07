import XCTest
@testable import BambuGateway

@MainActor
final class AppViewModelSliceStateResetTests: XCTestCase {
    /// Reproduces the "stuck at Slicing 100%" bug: a launch-time slice-job
    /// resume leaves the global progress flags set, and loading a new file must
    /// clear them so Preview/Print become available again.
    func test_freshSliceContext_clearsResumedSliceProgressState() {
        let vm = AppViewModel.makeForTesting()
        // Simulate the state a stuck `resumePersistedSliceJob()` leaves behind.
        vm.isLoadingPreview = true
        vm.slicingProgress = 100
        vm.slicingPhase = "Slicing"

        vm.beginFreshSliceContextForTesting()

        XCTAssertFalse(vm.isLoadingPreview)
        XCTAssertFalse(vm.isSubmitting)
        XCTAssertNil(vm.slicingProgress)
        XCTAssertNil(vm.slicingPhase)
    }

    func test_freshSliceContext_clearsSubmittingState() {
        let vm = AppViewModel.makeForTesting()
        vm.isSubmitting = true
        vm.slicingProgress = 100

        vm.beginFreshSliceContextForTesting()

        XCTAssertFalse(vm.isSubmitting)
        XCTAssertNil(vm.slicingProgress)
    }
}

extension AppViewModel {
    func beginFreshSliceContextForTesting() {
        resetActiveSliceState()
    }
}
