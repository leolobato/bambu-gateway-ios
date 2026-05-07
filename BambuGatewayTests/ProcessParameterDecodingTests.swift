import XCTest
@testable import BambuGateway

final class ProcessParameterDecodingTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    func test_decodeProcessOption_floatWithRange_succeeds() throws {
        let json = #"""
        {
          "key": "layer_height",
          "label": "Layer height",
          "category": "Quality",
          "tooltip": "Slicing height for every layer",
          "type": "coFloat",
          "sidetext": "mm",
          "default": "0.2",
          "min": 0.0,
          "max": null,
          "enum_values": null,
          "enum_labels": null,
          "mode": "simple",
          "gui_type": "",
          "nullable": false,
          "readonly": false
        }
        """#.data(using: .utf8)!

        let option = try decoder().decode(ProcessOption.self, from: json)

        XCTAssertEqual(option.key, "layer_height")
        XCTAssertEqual(option.label, "Layer height")
        XCTAssertEqual(option.type, .float)
        XCTAssertEqual(option.sidetext, "mm")
        XCTAssertEqual(option.default, "0.2")
        XCTAssertEqual(option.min, 0.0)
        XCTAssertNil(option.max)
        XCTAssertNil(option.enumValues)
        XCTAssertEqual(option.mode, "simple")
        XCTAssertFalse(option.readonly)
    }

    func test_decodeProcessOption_enum_succeeds() throws {
        let json = #"""
        {
          "key": "seam_position",
          "label": "Seam position",
          "category": "Quality",
          "tooltip": "...",
          "type": "coEnum",
          "sidetext": "",
          "default": "aligned",
          "min": null,
          "max": null,
          "enum_values": ["nearest", "aligned", "back", "random"],
          "enum_labels": ["Nearest", "Aligned", "Back", "Random"],
          "mode": "simple",
          "gui_type": "",
          "nullable": false,
          "readonly": false
        }
        """#.data(using: .utf8)!

        let option = try decoder().decode(ProcessOption.self, from: json)

        XCTAssertEqual(option.type, .enum)
        XCTAssertEqual(option.enumValues, ["nearest", "aligned", "back", "random"])
        XCTAssertEqual(option.enumLabels, ["Nearest", "Aligned", "Back", "Random"])
    }

    func test_decodeCatalogue_keyedByOptionKey_succeeds() throws {
        let json = #"""
        {
          "version": "2.3.2-41",
          "options": {
            "layer_height": {
              "key": "layer_height",
              "label": "Layer height",
              "category": "Quality",
              "tooltip": "",
              "type": "coFloat",
              "sidetext": "mm",
              "default": "0.2",
              "min": null,
              "max": null,
              "enum_values": null,
              "enum_labels": null,
              "mode": "simple",
              "gui_type": "",
              "nullable": false,
              "readonly": false
            }
          }
        }
        """#.data(using: .utf8)!

        let cat = try decoder().decode(ProcessOptionsCatalogue.self, from: json)

        XCTAssertEqual(cat.version, "2.3.2-41")
        XCTAssertEqual(cat.options["layer_height"]?.label, "Layer height")
    }

    func test_decodeLayout_pagesAndOptgroups_preserveOrder() throws {
        let json = #"""
        {
          "version": "2.3.2-41",
          "allowlist_revision": "2026-05-06.1",
          "pages": [
            {
              "label": "Quality",
              "optgroups": [
                {"label": "Layer height", "options": ["layer_height", "initial_layer_print_height"]}
              ]
            },
            {
              "label": "Strength",
              "optgroups": [
                {"label": "Walls", "options": ["wall_loops"]}
              ]
            }
          ]
        }
        """#.data(using: .utf8)!

        let layout = try decoder().decode(ProcessLayout.self, from: json)

        XCTAssertEqual(layout.allowlistRevision, "2026-05-06.1")
        XCTAssertEqual(layout.pages.map(\.label), ["Quality", "Strength"])
        XCTAssertEqual(layout.pages[0].optgroups[0].options, ["layer_height", "initial_layer_print_height"])
    }

    func test_decodeProcessModifications_full_succeeds() throws {
        let json = #"""
        {
          "process_setting_id": "Custom 0.20mm Standard",
          "modified_keys": ["layer_height", "wall_loops"],
          "values": {
            "layer_height": "0.16",
            "wall_loops": "3"
          }
        }
        """#.data(using: .utf8)!

        let mods = try decoder().decode(ProcessModifications.self, from: json)

        XCTAssertEqual(mods.processSettingId, "Custom 0.20mm Standard")
        XCTAssertEqual(mods.modifiedKeys, ["layer_height", "wall_loops"])
        XCTAssertEqual(mods.values["layer_height"], "0.16")
    }

    func test_decodeProcessModifications_emptyValues_succeeds() throws {
        let json = #"""
        {"process_setting_id": "", "modified_keys": [], "values": {}}
        """#.data(using: .utf8)!

        let mods = try decoder().decode(ProcessModifications.self, from: json)

        XCTAssertEqual(mods.processSettingId, "")
        XCTAssertTrue(mods.modifiedKeys.isEmpty)
        XCTAssertTrue(mods.values.isEmpty)
    }

    func test_decodeProcessOverrideApplied_succeeds() throws {
        let json = #"""
        [{"key": "layer_height", "value": "0.16", "previous": "0.20"}]
        """#.data(using: .utf8)!

        let applied = try decoder().decode([ProcessOverrideApplied].self, from: json)

        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied[0].key, "layer_height")
        XCTAssertEqual(applied[0].previous, "0.20")
    }
}
