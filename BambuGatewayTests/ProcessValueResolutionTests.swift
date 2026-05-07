import XCTest
@testable import BambuGateway

final class ProcessValueResolutionTests: XCTestCase {
    private let layerHeight = ProcessOption(
        key: "layer_height", label: "Layer height", category: "Quality",
        tooltip: "", type: .float, sidetext: "mm", default: "0.20",
        min: nil, max: nil, enumValues: nil, enumLabels: nil,
        mode: "simple", guiType: "", nullable: false, readonly: false
    )

    func test_resolve_userOverride_winsOverEverything() {
        let mods = ProcessModifications(
            processSettingId: "P", modifiedKeys: ["layer_height"],
            values: ["layer_height": "0.16"]
        )
        let value = resolveProcessValue(
            key: "layer_height",
            option: layerHeight,
            modifications: mods,
            baseline: ["layer_height": "0.18"],
            overrides: ["layer_height": "0.20"]
        )
        XCTAssertEqual(value, "0.20")
    }

    func test_resolve_threeMFValue_winsOverBaseline() {
        let mods = ProcessModifications(
            processSettingId: "P", modifiedKeys: ["layer_height"],
            values: ["layer_height": "0.16"]
        )
        let value = resolveProcessValue(
            key: "layer_height",
            option: layerHeight,
            modifications: mods,
            baseline: ["layer_height": "0.18"],
            overrides: [:]
        )
        XCTAssertEqual(value, "0.16")
    }

    func test_resolve_baseline_winsOverCatalogueDefault() {
        let mods = ProcessModifications(processSettingId: "P", modifiedKeys: [], values: [:])
        let value = resolveProcessValue(
            key: "layer_height",
            option: layerHeight,
            modifications: mods,
            baseline: ["layer_height": "0.18"],
            overrides: [:]
        )
        XCTAssertEqual(value, "0.18")
    }

    func test_resolve_fallsBackToCatalogueDefault() {
        let mods = ProcessModifications(processSettingId: "P", modifiedKeys: [], values: [:])
        let value = resolveProcessValue(
            key: "layer_height",
            option: layerHeight,
            modifications: mods,
            baseline: [:],
            overrides: [:]
        )
        XCTAssertEqual(value, "0.20")
    }

    func test_revertTarget_excludesUserOverride() {
        let mods = ProcessModifications(
            processSettingId: "P", modifiedKeys: ["layer_height"],
            values: ["layer_height": "0.16"]
        )
        let target = revertTargetForProcessValue(
            key: "layer_height",
            option: layerHeight,
            modifications: mods,
            baseline: ["layer_height": "0.18"]
        )
        XCTAssertEqual(target.value, "0.16")
        XCTAssertEqual(target.source, .threeMF)
    }

    func test_revertTarget_unmodifiedKey_pointsAtBaseline() {
        let mods = ProcessModifications(processSettingId: "P", modifiedKeys: [], values: [:])
        let target = revertTargetForProcessValue(
            key: "layer_height",
            option: layerHeight,
            modifications: mods,
            baseline: ["layer_height": "0.18"]
        )
        XCTAssertEqual(target.value, "0.18")
        XCTAssertEqual(target.source, .systemDefault)
    }
}
