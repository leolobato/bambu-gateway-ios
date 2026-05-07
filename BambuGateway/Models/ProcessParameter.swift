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
}

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

struct ProcessLayout: Decodable {
    let version: String
    let allowlistRevision: String
    let pages: [ProcessPage]
}
