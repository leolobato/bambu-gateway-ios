import XCTest
@testable import BambuGateway

final class PrintEstimateDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> PrintEstimate {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PrintEstimate.self, from: Data(json.utf8))
    }

    func test_decodesAllFields() throws {
        let json = """
        {
          "total_filament_millimeters": 9280.0,
          "total_filament_grams": 29.46,
          "model_filament_millimeters": 9120.0,
          "model_filament_grams": 28.96,
          "prepare_seconds": 356,
          "model_print_seconds": 9000,
          "total_seconds": 9356
        }
        """
        let estimate = try decode(json)
        XCTAssertEqual(estimate.totalFilamentMillimeters, 9280.0)
        XCTAssertEqual(estimate.totalFilamentGrams, 29.46)
        XCTAssertEqual(estimate.modelFilamentMillimeters, 9120.0)
        XCTAssertEqual(estimate.modelFilamentGrams, 28.96)
        XCTAssertEqual(estimate.prepareSeconds, 356)
        XCTAssertEqual(estimate.modelPrintSeconds, 9000)
        XCTAssertEqual(estimate.totalSeconds, 9356)
        XCTAssertFalse(estimate.isEmpty)
    }

    func test_decodesEmptyObjectAsAllNil() throws {
        let estimate = try decode("{}")
        XCTAssertNil(estimate.totalFilamentMillimeters)
        XCTAssertNil(estimate.totalSeconds)
        XCTAssertTrue(estimate.isEmpty)
    }

    func test_decodesPartialFields() throws {
        let json = """
        { "total_seconds": 600, "total_filament_grams": 5.0 }
        """
        let estimate = try decode(json)
        XCTAssertEqual(estimate.totalSeconds, 600)
        XCTAssertEqual(estimate.totalFilamentGrams, 5.0)
        XCTAssertNil(estimate.modelPrintSeconds)
        XCTAssertFalse(estimate.isEmpty)
    }
}

final class PrintResponseEstimateTests: XCTestCase {
    private func decode(_ json: String) throws -> PrintResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PrintResponse.self, from: Data(json.utf8))
    }

    func test_decodesPrintResponseWithEstimate() throws {
        let json = """
        {
          "status": "ok",
          "file_name": "demo.3mf",
          "printer_id": "P01",
          "was_sliced": true,
          "estimate": { "total_seconds": 9356, "total_filament_grams": 29.46 }
        }
        """
        let response = try decode(json)
        XCTAssertEqual(response.estimate?.totalSeconds, 9356)
        XCTAssertEqual(response.estimate?.totalFilamentGrams, 29.46)
    }

    func test_decodesPrintResponseWithoutEstimate() throws {
        let json = """
        {
          "status": "ok",
          "file_name": "demo.3mf",
          "printer_id": "P01",
          "was_sliced": false
        }
        """
        let response = try decode(json)
        XCTAssertNil(response.estimate)
    }
}
