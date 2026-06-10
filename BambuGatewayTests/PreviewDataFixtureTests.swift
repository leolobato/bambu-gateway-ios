import XCTest
import GCodePreview
@testable import BambuGateway

final class PreviewDataFixtureTests: XCTestCase {
    func test_decodeSimpleFixture_producesVertices() throws {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "simple.preview", withExtension: "bin") else {
            let resources = bundle.paths(forResourcesOfType: "bin", inDirectory: nil)
            XCTFail("simple.preview.bin not found in test bundle. .bin resources: \(resources)")
            return
        }
        let preview = try PreviewData(contentsOf: url)
        XCTAssertEqual(preview.formatVersion, 1)
        XCTAssertGreaterThan(preview.vertexCount, 0)
        XCTAssertGreaterThan(preview.layerCount, 0)
    }
}
