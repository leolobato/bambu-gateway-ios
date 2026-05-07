import XCTest
@testable import BambuGateway

@MainActor
final class ProcessOptionsStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }

    private func makeClient() -> GatewayClient {
        GatewayClient(baseURLString: "http://gateway.test", session: URLProtocolStub.makeSession())
    }

    private func enqueueCatalogue(version: String = "2.3.2-41") {
        let body = """
        {
          "version": "\(version)",
          "options": {
            "layer_height": {
              "key": "layer_height", "label": "Layer height", "category": "Quality",
              "tooltip": "", "type": "coFloat", "sidetext": "mm", "default": "0.2",
              "min": null, "max": null, "enum_values": null, "enum_labels": null,
              "mode": "simple", "gui_type": "", "nullable": false, "readonly": false
            }
          }
        }
        """.data(using: .utf8)!
        URLProtocolStub.enqueue(path: "/api/options/process", response: .init(body: body))
    }

    private func enqueueLayout(version: String = "2.3.2-41", revision: String = "2026-05-06.1") {
        let body = """
        {
          "version": "\(version)",
          "allowlist_revision": "\(revision)",
          "pages": [
            {"label": "Quality", "optgroups": [
              {"label": "Layer height", "options": ["layer_height"]}
            ]}
          ]
        }
        """.data(using: .utf8)!
        URLProtocolStub.enqueue(path: "/api/options/process/layout", response: .init(body: body))
    }

    func test_loadCatalogue_populatesPublishedField() async throws {
        enqueueCatalogue()
        let store = ProcessOptionsStore(client: makeClient())

        await store.loadCatalogueIfNeeded()

        XCTAssertEqual(store.catalogue?.version, "2.3.2-41")
        XCTAssertEqual(store.catalogue?.options["layer_height"]?.type, .float)
    }

    func test_loadCatalogue_concurrentCallers_coalesceSingleRequest() async throws {
        enqueueCatalogue()
        let store = ProcessOptionsStore(client: makeClient())

        async let a: () = store.loadCatalogueIfNeeded()
        async let b: () = store.loadCatalogueIfNeeded()
        async let c: () = store.loadCatalogueIfNeeded()
        _ = await (a, b, c)

        XCTAssertEqual(URLProtocolStub.requestedPaths.filter { $0 == "/api/options/process" }.count, 1)
    }

    func test_loadCatalogue_secondCallAfterSuccess_doesNotRefetch() async throws {
        enqueueCatalogue()
        let store = ProcessOptionsStore(client: makeClient())

        await store.loadCatalogueIfNeeded()
        await store.loadCatalogueIfNeeded()

        XCTAssertEqual(URLProtocolStub.requestedPaths.filter { $0 == "/api/options/process" }.count, 1)
    }

    func test_loadLayout_populatesAllowlistedKeys() async throws {
        enqueueLayout()
        let store = ProcessOptionsStore(client: makeClient())

        await store.loadLayoutIfNeeded()

        XCTAssertEqual(store.layout?.allowlistRevision, "2026-05-06.1")
        XCTAssertTrue(store.allowlistedKeys.contains("layer_height"))
    }

    func test_loadLayout_revisionChange_replacesCache() async throws {
        enqueueLayout(revision: "2026-05-06.1")
        let store = ProcessOptionsStore(client: makeClient())
        await store.loadLayoutIfNeeded()
        XCTAssertEqual(store.layout?.allowlistRevision, "2026-05-06.1")

        enqueueLayout(revision: "2026-06-01.1")
        await store.refreshLayout()

        XCTAssertEqual(store.layout?.allowlistRevision, "2026-06-01.1")
    }

    func test_loadCatalogue_serverError_setsLoadError() async throws {
        URLProtocolStub.enqueue(
            path: "/api/options/process",
            response: .init(statusCode: 500, body: Data())
        )
        let store = ProcessOptionsStore(client: makeClient())

        await store.loadCatalogueIfNeeded()

        XCTAssertNil(store.catalogue)
        XCTAssertNotNil(store.loadError)
    }
}
