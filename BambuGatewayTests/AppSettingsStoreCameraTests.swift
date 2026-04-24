import XCTest
@testable import BambuGateway

final class AppSettingsStoreCameraTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "bambu_gateway_ios.tests.camera"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_persistExternalCameraURL_roundTrips() {
        let store = AppSettingsStore(defaults: defaults)
        var settings = PersistedSettings.default
        var selection = PerPrinterSelection.empty
        selection.externalCameraURL = "rtsp://user:pass@192.168.1.50/stream"
        settings.perPrinter["A"] = selection

        store.save(settings)
        let loaded = store.load()

        XCTAssertEqual(
            loaded.perPrinter["A"]?.externalCameraURL,
            "rtsp://user:pass@192.168.1.50/stream"
        )
    }

    func test_decodeLegacyPayloadWithoutExternalCameraURL_defaultsToNil() throws {
        let legacyJSON = """
        {
            "gatewayBaseURL": "http://x",
            "selectedPrinterId": "A",
            "perPrinter": {
                "A": {
                    "machineProfileId": "m",
                    "processProfileId": "p",
                    "plateType": "pt",
                    "trayProfileBySlot": {},
                    "filamentTrayByIndex": {}
                }
            }
        }
        """
        defaults.set(Data(legacyJSON.utf8), forKey: "bambu_gateway_ios.settings")

        let store = AppSettingsStore(defaults: defaults)
        let loaded = store.load()

        XCTAssertNil(loaded.perPrinter["A"]?.externalCameraURL)
    }
}
