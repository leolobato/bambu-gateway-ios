import XCTest
@testable import BambuGateway

final class SliceJobDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> SliceJob {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SliceJob.self, from: Data(json.utf8))
    }

    func test_decodesAllFields_fromListEntry() throws {
        let json = """
        {
          "job_id": "abc-123",
          "status": "ready",
          "progress": 100,
          "phase": null,
          "filename": "benchy.3mf",
          "printer_id": "P1S-001",
          "auto_print": false,
          "error": null,
          "created_at": "2026-04-28T15:30:00Z",
          "updated_at": "2026-04-28T15:31:12Z",
          "output_size": 482910,
          "has_thumbnail": true,
          "estimate": {
            "total_filament_grams": 12.5,
            "total_seconds": 1830
          },
          "settings_transfer": null
        }
        """
        let job = try decode(json)
        XCTAssertEqual(job.jobId, "abc-123")
        XCTAssertEqual(job.status, "ready")
        XCTAssertEqual(job.progress, 100)
        XCTAssertNil(job.phase)
        XCTAssertEqual(job.filename, "benchy.3mf")
        XCTAssertEqual(job.printerId, "P1S-001")
        XCTAssertFalse(job.autoPrint)
        XCTAssertNil(job.error)
        XCTAssertEqual(job.createdAt, "2026-04-28T15:30:00Z")
        XCTAssertEqual(job.updatedAt, "2026-04-28T15:31:12Z")
        XCTAssertEqual(job.outputSize, 482910)
        XCTAssertTrue(job.hasThumbnail)
        XCTAssertEqual(job.estimate?.totalSeconds, 1830)
        XCTAssertEqual(job.id, "abc-123")
    }

    func test_decodesInFlightJob_withNullOutputAndEstimate() throws {
        let json = """
        {
          "job_id": "queued-1",
          "status": "slicing",
          "progress": 42,
          "phase": "Optimizing toolpath",
          "filename": "calibration.3mf",
          "printer_id": null,
          "auto_print": false,
          "error": null,
          "created_at": "2026-04-28T15:30:00Z",
          "updated_at": "2026-04-28T15:30:08Z",
          "output_size": null,
          "has_thumbnail": false,
          "estimate": null
        }
        """
        let job = try decode(json)
        XCTAssertEqual(job.status, "slicing")
        XCTAssertEqual(job.progress, 42)
        XCTAssertEqual(job.phase, "Optimizing toolpath")
        XCTAssertNil(job.printerId)
        XCTAssertNil(job.outputSize)
        XCTAssertFalse(job.hasThumbnail)
        XCTAssertNil(job.estimate)
    }

    func test_decodesListResponse_withMultipleJobs() throws {
        let json = """
        {
          "jobs": [
            {
              "job_id": "a",
              "status": "ready",
              "progress": 100,
              "phase": null,
              "filename": "one.3mf",
              "printer_id": null,
              "auto_print": false,
              "error": null,
              "created_at": "2026-04-28T15:30:00Z",
              "updated_at": "2026-04-28T15:31:00Z",
              "output_size": 100,
              "has_thumbnail": true,
              "estimate": null
            },
            {
              "job_id": "b",
              "status": "failed",
              "progress": 50,
              "phase": null,
              "filename": "two.3mf",
              "printer_id": null,
              "auto_print": false,
              "error": "boom",
              "created_at": "2026-04-28T16:00:00Z",
              "updated_at": "2026-04-28T16:00:30Z",
              "output_size": null,
              "has_thumbnail": false,
              "estimate": null
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(SliceJobListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.jobs.count, 2)
        XCTAssertEqual(response.jobs[0].jobId, "a")
        XCTAssertEqual(response.jobs[1].error, "boom")
    }

    func test_isTerminal_classifiesStatuses() {
        let terminalStatuses = ["ready", "failed", "cancelled"]
        let liveStatuses = ["queued", "slicing", "uploading"]
        for raw in terminalStatuses {
            XCTAssertTrue(makeJob(status: raw).isTerminal, "expected \(raw) to be terminal")
        }
        for raw in liveStatuses {
            XCTAssertFalse(makeJob(status: raw).isTerminal, "expected \(raw) to be non-terminal")
        }
    }

    func test_decodes_printedFlag_whenPresent() throws {
        let json = """
        {
          "job_id": "p1",
          "status": "ready",
          "progress": 100,
          "phase": null,
          "filename": "x.3mf",
          "printer_id": "P1S-001",
          "auto_print": true,
          "error": null,
          "created_at": "2026-04-28T15:30:00Z",
          "updated_at": "2026-04-28T15:31:00Z",
          "output_size": 100,
          "has_thumbnail": false,
          "estimate": null,
          "printed": true
        }
        """
        let job = try decode(json)
        XCTAssertTrue(job.isPrinted)
        XCTAssertEqual(job.printed, true)
    }

    func test_decodes_jobWithoutPrintedField_defaultsIsPrintedFalse() throws {
        // Older gateways won't include `printed`; the field must remain
        // optional so decoding doesn't fail.
        let json = """
        {
          "job_id": "old",
          "status": "ready",
          "progress": 100,
          "phase": null,
          "filename": "x.3mf",
          "printer_id": null,
          "auto_print": false,
          "error": null,
          "created_at": "2026-04-28T15:30:00Z",
          "updated_at": "2026-04-28T15:31:00Z",
          "output_size": 100,
          "has_thumbnail": false,
          "estimate": null
        }
        """
        let job = try decode(json)
        XCTAssertNil(job.printed)
        XCTAssertFalse(job.isPrinted)
    }

    private func makeJob(status: String) -> SliceJob {
        SliceJob(
            jobId: "id",
            status: status,
            progress: 0,
            phase: nil,
            filename: "f.3mf",
            printerId: nil,
            autoPrint: false,
            error: nil,
            createdAt: "2026-04-28T15:30:00Z",
            updatedAt: "2026-04-28T15:30:00Z",
            outputSize: nil,
            hasThumbnail: false,
            estimate: nil,
            printed: nil
        )
    }
}
