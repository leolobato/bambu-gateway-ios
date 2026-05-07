import XCTest
@testable import BambuGateway

final class ThreeMFInfoDecodingTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    func test_decodeThreeMFInfo_withProcessModifications_succeeds() throws {
        let json = #"""
        {
          "plates": [],
          "filaments": [],
          "print_profile": {"print_settings_id": "P", "layer_height": "0.2"},
          "printer": {"printer_settings_id": "X", "printer_model": "A1", "nozzle_diameter": "0.4"},
          "has_gcode": false,
          "process_modifications": {
            "process_setting_id": "Custom 0.20mm Standard",
            "modified_keys": ["layer_height"],
            "values": {"layer_height": "0.16"}
          }
        }
        """#.data(using: .utf8)!

        let info = try decoder().decode(ThreeMFInfo.self, from: json)

        XCTAssertEqual(info.processModifications?.processSettingId, "Custom 0.20mm Standard")
        XCTAssertEqual(info.processModifications?.values["layer_height"], "0.16")
    }

    func test_decodeThreeMFInfo_olderGatewayWithoutProcessModifications_decodesNil() throws {
        let json = #"""
        {
          "plates": [],
          "filaments": [],
          "print_profile": {"print_settings_id": "P", "layer_height": "0.2"},
          "printer": {"printer_settings_id": "X", "printer_model": "A1", "nozzle_diameter": "0.4"},
          "has_gcode": false
        }
        """#.data(using: .utf8)!

        let info = try decoder().decode(ThreeMFInfo.self, from: json)

        XCTAssertNil(info.processModifications)
    }
}
