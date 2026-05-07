import XCTest
@testable import BambuGateway

@MainActor
final class AppViewModelProcessOverridesTests: XCTestCase {
    func test_setProcessOverride_updatesMap() {
        let vm = AppViewModel.makeForTesting()

        vm.setProcessOverride(key: "layer_height", value: "0.16")

        XCTAssertEqual(vm.processOverrides["layer_height"], "0.16")
    }

    func test_revertProcessOverride_removesKey() {
        let vm = AppViewModel.makeForTesting()
        vm.setProcessOverride(key: "layer_height", value: "0.16")

        vm.revertProcessOverride(key: "layer_height")

        XCTAssertNil(vm.processOverrides["layer_height"])
    }

    func test_resetAllProcessOverrides_clearsMap() {
        let vm = AppViewModel.makeForTesting()
        vm.setProcessOverride(key: "a", value: "1")
        vm.setProcessOverride(key: "b", value: "2")

        vm.resetAllProcessOverrides()

        XCTAssertTrue(vm.processOverrides.isEmpty)
    }

    func test_clearSelectedFile_clearsOverridesAndBaseline() {
        let vm = AppViewModel.makeForTesting()
        vm.setProcessOverride(key: "layer_height", value: "0.16")
        vm.processBaseline = ["layer_height": "0.20"]

        vm.clearSelectedFileForTesting()

        XCTAssertTrue(vm.processOverrides.isEmpty)
        XCTAssertTrue(vm.processBaseline.isEmpty)
    }
}

extension AppViewModel {
    /// Test-only constructor that uses an isolated UserDefaults suite so
    /// each test gets a fresh, empty `AppSettingsStore`.
    static func makeForTesting() -> AppViewModel {
        let suiteName = "test.AppViewModelProcessOverrides.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppViewModel(settingsStore: AppSettingsStore(defaults: defaults))
    }

    func clearSelectedFileForTesting() {
        clearSelectedFile()
    }
}
