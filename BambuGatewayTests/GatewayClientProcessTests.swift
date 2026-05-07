import XCTest
@testable import BambuGateway

final class GatewayClientProcessTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }

    private func makeClient() -> GatewayClient {
        GatewayClient(baseURLString: "http://gateway.test", session: URLProtocolStub.makeSession())
    }

    func test_fetchProcessOptions_returnsCatalogue() async throws {
        let body = #"""
        {
          "version": "2.3.2-41",
          "options": {
            "layer_height": {
              "key": "layer_height", "label": "Layer height", "category": "Quality",
              "tooltip": "", "type": "coFloat", "sidetext": "mm", "default": "0.2",
              "min": null, "max": null, "enum_values": null, "enum_labels": null,
              "mode": "simple", "gui_type": "", "nullable": false, "readonly": false
            }
          }
        }
        """#.data(using: .utf8)!
        URLProtocolStub.enqueue(path: "/api/options/process", response: .init(body: body))

        let cat = try await makeClient().fetchProcessOptions()

        XCTAssertEqual(cat.version, "2.3.2-41")
        XCTAssertEqual(cat.options["layer_height"]?.type, .float)
        XCTAssertEqual(URLProtocolStub.requestedPaths, ["/api/options/process"])
    }

    func test_fetchProcessLayout_returnsLayout() async throws {
        let body = #"""
        {
          "version": "2.3.2-41",
          "allowlist_revision": "2026-05-06.1",
          "pages": [
            {"label": "Quality", "optgroups": [
              {"label": "Layer height", "options": ["layer_height"]}
            ]}
          ]
        }
        """#.data(using: .utf8)!
        URLProtocolStub.enqueue(path: "/api/options/process/layout", response: .init(body: body))

        let layout = try await makeClient().fetchProcessLayout()

        XCTAssertEqual(layout.allowlistRevision, "2026-05-06.1")
        XCTAssertEqual(layout.pages[0].optgroups[0].options, ["layer_height"])
    }
}
