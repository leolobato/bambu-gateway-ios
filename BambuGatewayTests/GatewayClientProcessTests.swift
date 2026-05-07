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

    func test_fetchProcessProfile_returnsValues() async throws {
        let body = #"""
        {
          "setting_id": "Custom 0.20mm Standard",
          "values": {"layer_height": "0.20", "wall_loops": "2"}
        }
        """#.data(using: .utf8)!
        URLProtocolStub.enqueue(
            path: "/api/slicer/processes/Custom%200.20mm%20Standard",
            response: .init(body: body)
        )

        let profile = try await makeClient().fetchProcessProfile(settingId: "Custom 0.20mm Standard")

        XCTAssertEqual(profile.settingId, "Custom 0.20mm Standard")
        XCTAssertEqual(profile.values["layer_height"], "0.20")
    }

    func test_addProcessOverridesField_withValues_writesJsonStringField() throws {
        var form = MultipartFormData()
        let client = makeClient()

        try client.addProcessOverridesField(
            to: &form,
            overrides: ["layer_height": "0.16", "wall_loops": "3"]
        )
        form.finalize()

        let body = String(data: form.body, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("name=\"process_overrides\""), "field name missing in body")
        XCTAssertTrue(body.contains("\"layer_height\":\"0.16\""), "layer_height missing in JSON value")
        XCTAssertTrue(body.contains("\"wall_loops\":\"3\""), "wall_loops missing in JSON value")
    }

    func test_addProcessOverridesField_withNil_omitsField() throws {
        var form = MultipartFormData()
        let client = makeClient()

        try client.addProcessOverridesField(to: &form, overrides: nil)
        form.finalize()

        let body = String(data: form.body, encoding: .utf8) ?? ""
        XCTAssertFalse(body.contains("name=\"process_overrides\""))
    }

    func test_addProcessOverridesField_withEmptyDict_omitsField() throws {
        var form = MultipartFormData()
        let client = makeClient()

        try client.addProcessOverridesField(to: &form, overrides: [:])
        form.finalize()

        let body = String(data: form.body, encoding: .utf8) ?? ""
        XCTAssertFalse(body.contains("name=\"process_overrides\""))
    }

    func test_printSubmission_initializesWithProcessOverrides() {
        let submission = PrintSubmission(
            file: Imported3MFFile(fileName: "x.3mf", data: Data([0x01])),
            printerId: "P1",
            plateId: nil,
            plateType: "",
            machineProfile: "GM004",
            processProfile: "GP004",
            filamentOverrides: [:],
            processOverrides: ["layer_height": "0.16"]
        )

        XCTAssertEqual(submission.processOverrides?["layer_height"], "0.16")
    }
}
