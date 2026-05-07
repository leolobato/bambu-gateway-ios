import XCTest
@testable import BambuGateway

final class SettingsTransferInfoDecodingTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    func test_decode_withProcessOverridesApplied_succeeds() throws {
        let json = #"""
        {
          "status": "applied",
          "transferred": [],
          "filaments": [],
          "process_overrides_applied": [
            {"key": "layer_height", "value": "0.16", "previous": "0.20"}
          ]
        }
        """#.data(using: .utf8)!

        let info = try decoder().decode(SettingsTransferInfo.self, from: json)

        XCTAssertEqual(info.processOverridesApplied?.count, 1)
        XCTAssertEqual(info.processOverridesApplied?[0].key, "layer_height")
    }

    func test_decode_withoutProcessOverridesApplied_decodesNil() throws {
        let json = #"""
        {"status": "applied", "transferred": [], "filaments": []}
        """#.data(using: .utf8)!

        let info = try decoder().decode(SettingsTransferInfo.self, from: json)

        XCTAssertNil(info.processOverridesApplied)
    }
}
