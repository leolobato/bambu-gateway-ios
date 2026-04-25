import XCTest
@testable import BambuGateway

final class PrintEstimationFormattingTests: XCTestCase {
    private let enUS = Locale(identifier: "en_US")

    func test_formatsLengthInMeters() {
        XCTAssertEqual(PrintEstimateFormatters.formatLength(millimeters: 9280, locale: enUS), "9.28 m")
        XCTAssertEqual(PrintEstimateFormatters.formatLength(millimeters: 0, locale: enUS), "0.00 m")
    }

    func test_formatsLengthWithLocalizedDecimal() {
        let ptBR = Locale(identifier: "pt_BR")
        XCTAssertEqual(PrintEstimateFormatters.formatLength(millimeters: 9280, locale: ptBR), "9,28 m")
    }

    func test_formatsLengthReturnsNilForNil() {
        XCTAssertNil(PrintEstimateFormatters.formatLength(millimeters: nil, locale: enUS))
    }

    func test_formatsMass() {
        XCTAssertEqual(PrintEstimateFormatters.formatMass(grams: 29.46, locale: enUS), "29.46 g")
    }

    func test_formatsMassReturnsNilForNil() {
        XCTAssertNil(PrintEstimateFormatters.formatMass(grams: nil, locale: enUS))
    }

    func test_formatsDurationUnderOneMinute() {
        XCTAssertEqual(PrintEstimateFormatters.formatDuration(seconds: 45), "45s")
    }

    func test_formatsDurationMinutesAndSeconds() {
        XCTAssertEqual(PrintEstimateFormatters.formatDuration(seconds: 356), "5m 56s")
    }

    func test_formatsDurationHoursAndMinutes() {
        XCTAssertEqual(PrintEstimateFormatters.formatDuration(seconds: 9000), "2h 30m")
    }

    func test_formatsDurationZero() {
        XCTAssertEqual(PrintEstimateFormatters.formatDuration(seconds: 0), "0s")
    }

    func test_formatsDurationReturnsNilForNil() {
        XCTAssertNil(PrintEstimateFormatters.formatDuration(seconds: nil))
    }
}
