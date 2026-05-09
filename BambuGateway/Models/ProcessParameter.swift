import Foundation

enum ProcessOptionType: String, Decodable {
    case bool = "coBool"
    case float = "coFloat"
    case floats = "coFloats"
    case int = "coInt"
    case ints = "coInts"
    case string = "coString"
    case strings = "coStrings"
    case percent = "coPercent"
    case percents = "coPercents"
    case floatOrPercent = "coFloatOrPercent"
    case floatsOrPercents = "coFloatsOrPercents"
    case point = "coPoint"
    case points = "coPoints"
    case point3 = "coPoint3"
    case bools = "coBools"
    case `enum` = "coEnum"
    case none = "coNone"
    // Slicer-emitted catch-all for options whose libslic3r type doesn't
    // map to a known ConfigOptionType — e.g. `default_nozzle_volume_type`
    // surfaces as `coUnknown`. Keeping this case explicit (rather than
    // raising on decode) means a single rogue option can't take down the
    // whole catalogue parse, and forward-compat with future libslic3r
    // additions degrades gracefully to read-only display.
    case unknown = "coUnknown"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Fall back to .unknown for any string libslic3r might invent
        // later — same rationale as the explicit `coUnknown` case above.
        self = ProcessOptionType(rawValue: raw) ?? .unknown
    }
}

struct ProcessOption: Decodable, Hashable {
    let key: String
    let label: String
    let category: String
    let tooltip: String
    let type: ProcessOptionType
    let sidetext: String
    let `default`: String
    let min: Double?
    let max: Double?
    let enumValues: [String]?
    let enumLabels: [String]?
    let mode: String
    let guiType: String
    let nullable: Bool
    let readonly: Bool

    // Explicit CodingKeys so this struct decodes correctly under both
    // .useDefaultKeys (used for /api/slicer/options/process — see note on
    // ProcessOptionsCatalogue) and .convertFromSnakeCase. Identity-mapped
    // names are listed too because explicit CodingKeys are all-or-nothing.
    private enum CodingKeys: String, CodingKey {
        case key, label, category, tooltip, type, sidetext, `default`,
             min, max, mode, nullable, readonly
        case enumValues = "enum_values"
        case enumLabels = "enum_labels"
        case guiType = "gui_type"
    }
}

// Decoded with .useDefaultKeys — see GatewayClient.decodeWithRawKeys.
// .convertFromSnakeCase would mangle the option-id dictionary keys
// (e.g. "layer_height" → "layerHeight"), breaking lookups by id.
struct ProcessOptionsCatalogue: Decodable {
    let version: String
    let options: [String: ProcessOption]
}

struct ProcessOptgroup: Decodable, Hashable {
    let label: String
    let options: [String]
}

struct ProcessPage: Decodable, Hashable {
    let label: String
    let optgroups: [ProcessOptgroup]
}

// Decoded with .useDefaultKeys for symmetry with the catalogue, even
// though the layout has no dict-keyed sub-trees.
struct ProcessLayout: Decodable {
    let version: String
    let allowlistRevision: String
    let pages: [ProcessPage]

    private enum CodingKeys: String, CodingKey {
        case version, pages
        case allowlistRevision = "allowlist_revision"
    }
}

struct ProcessModifications: Decodable, Equatable {
    let processSettingId: String
    let modifiedKeys: [String]
    let values: [String: String]
}

struct ProcessOverrideApplied: Decodable, Hashable {
    let key: String
    let value: String
    let previous: String
}
