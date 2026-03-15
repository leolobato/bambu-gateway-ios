import Foundation

public enum MoveType: String, Sendable, CaseIterable, Hashable {
    case perimeter
    case infill
    case support
    case skirt
    case travel
    case unknown
}
