import XCTest
@testable import BambuGateway

final class AMSTrayDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> AMSTray {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(AMSTray.self, from: Data(json.utf8))
    }

    func test_decodesRemainingGrams() throws {
        let tray = try decode(#"{"slot": 3, "ams_id": 0, "tray_id": 3, "remain": 30, "remaining_grams": 280}"#)
        XCTAssertEqual(tray.remainingGrams, 280)
    }

    func test_nullRemainingGrams_decodesAsNil() throws {
        let tray = try decode(#"{"slot": 3, "ams_id": 0, "tray_id": 3, "remaining_grams": null}"#)
        XCTAssertNil(tray.remainingGrams)
    }

    func test_olderGatewayWithoutRemainingGrams_decodesAsNil() throws {
        let tray = try decode(#"{"slot": 3, "ams_id": 0, "tray_id": 3}"#)
        XCTAssertNil(tray.remainingGrams)
        XCTAssertEqual(tray.remain, -1)
    }
}
