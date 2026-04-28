import XCTest
@testable import BambuGateway

final class SliceJobDisplayStatusTests: XCTestCase {
    func test_printing_mapsToReady() {
        XCTAssertEqual(SliceJobDisplayStatus(rawStatus: "printing"), .ready)
    }

    func test_ready_staysReady() {
        XCTAssertEqual(SliceJobDisplayStatus(rawStatus: "ready"), .ready)
    }

    func test_inFlightStatuses_passThrough() {
        XCTAssertEqual(SliceJobDisplayStatus(rawStatus: "queued"), .queued)
        XCTAssertEqual(SliceJobDisplayStatus(rawStatus: "slicing"), .slicing)
        XCTAssertEqual(SliceJobDisplayStatus(rawStatus: "uploading"), .uploading)
    }

    func test_terminalErrorStatuses_passThrough() {
        XCTAssertEqual(SliceJobDisplayStatus(rawStatus: "failed"), .failed)
        XCTAssertEqual(SliceJobDisplayStatus(rawStatus: "cancelled"), .cancelled)
    }

    func test_unknownStatus_fallsBackToQueued() {
        XCTAssertEqual(SliceJobDisplayStatus(rawStatus: "wat"), .queued)
        XCTAssertEqual(SliceJobDisplayStatus(rawStatus: ""), .queued)
    }

    func test_isInFlight_trueOnlyForQueuedSlicingUploading() {
        XCTAssertTrue(SliceJobDisplayStatus.queued.isInFlight)
        XCTAssertTrue(SliceJobDisplayStatus.slicing.isInFlight)
        XCTAssertTrue(SliceJobDisplayStatus.uploading.isInFlight)
        XCTAssertFalse(SliceJobDisplayStatus.ready.isInFlight)
        XCTAssertFalse(SliceJobDisplayStatus.failed.isInFlight)
        XCTAssertFalse(SliceJobDisplayStatus.cancelled.isInFlight)
    }
}
