import XCTest
@testable import BambuGateway

final class MultipartFormDataTests: XCTestCase {
    func test_writeBodyToTemporaryFile_matchesInMemoryBody() throws {
        var form = MultipartFormData()
        form.addField(name: "alpha", value: "first")
        form.addFile(name: "file", fileName: "demo.bin", mimeType: "application/octet-stream", data: Data([0x01, 0x02, 0x03]))
        form.finalize()

        let url = try form.writeBody(toTemporaryFileNamed: "test-payload")

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.pathExtension, "multipart")
        XCTAssertTrue(url.path.contains(FileManager.default.temporaryDirectory.path))

        let written = try Data(contentsOf: url)
        XCTAssertEqual(written, form.body)

        try FileManager.default.removeItem(at: url)
    }

    func test_writeBodyToTemporaryFile_returnsUniqueURLsAcrossCalls() throws {
        var form = MultipartFormData()
        form.addField(name: "k", value: "v")
        form.finalize()

        let urlA = try form.writeBody(toTemporaryFileNamed: "concurrent")
        let urlB = try form.writeBody(toTemporaryFileNamed: "concurrent")

        XCTAssertNotEqual(urlA, urlB)
        try FileManager.default.removeItem(at: urlA)
        try FileManager.default.removeItem(at: urlB)
    }
}
