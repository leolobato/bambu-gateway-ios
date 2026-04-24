import XCTest
@testable import BambuGateway

final class PrinterStatusCameraDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> PrinterStatus {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PrinterStatus.self, from: data)
    }

    private let basePrinter = """
        "id": "A", "name": "X1C", "machine_model": "X1C",
        "online": true, "state": "IDLE", "speed_level": 2,
        "temperatures": {"nozzle_temp": 0, "nozzle_target": 0, "bed_temp": 0, "bed_target": 0}
    """

    func test_decode_cameraFieldMissing_cameraIsNil() throws {
        let json = "{ \(basePrinter) }"
        let printer = try decode(json)
        XCTAssertNil(printer.camera)
    }

    func test_decode_cameraFieldPresent_populatesAllFields() throws {
        let json = """
        {
            \(basePrinter),
            "camera": {
                "ip": "192.168.1.42",
                "access_code": "12345678",
                "transport": "rtsps",
                "chamber_light": { "supported": true, "on": false }
            }
        }
        """
        let printer = try decode(json)
        let camera = try XCTUnwrap(printer.camera)
        XCTAssertEqual(camera.ip, "192.168.1.42")
        XCTAssertEqual(camera.accessCode, "12345678")
        XCTAssertEqual(camera.transport, .rtsps)
        XCTAssertEqual(camera.chamberLight?.supported, true)
        XCTAssertEqual(camera.chamberLight?.on, false)
    }

    func test_decode_transportTcpJpeg_mapsCorrectly() throws {
        let json = """
        {
            \(basePrinter),
            "camera": {
                "ip": "10.0.0.5", "access_code": "abc", "transport": "tcp_jpeg",
                "chamber_light": { "supported": false, "on": null }
            }
        }
        """
        let printer = try decode(json)
        XCTAssertEqual(printer.camera?.transport, .tcpJPEG)
        XCTAssertEqual(printer.camera?.chamberLight?.supported, false)
        XCTAssertNil(printer.camera?.chamberLight?.on)
    }

    func test_decode_transportUnknown_decodesAsUnknown() throws {
        let json = """
        {
            \(basePrinter),
            "camera": {
                "ip": "1.1.1.1", "access_code": "x", "transport": "something_new",
                "chamber_light": { "supported": true, "on": true }
            }
        }
        """
        let printer = try decode(json)
        XCTAssertEqual(printer.camera?.transport, .unknown)
    }

    func test_decode_chamberLightMissing_isNil() throws {
        let json = """
        {
            \(basePrinter),
            "camera": { "ip": "1.1.1.1", "access_code": "x", "transport": "rtsps" }
        }
        """
        let printer = try decode(json)
        XCTAssertNotNil(printer.camera)
        XCTAssertNil(printer.camera?.chamberLight)
    }
}
