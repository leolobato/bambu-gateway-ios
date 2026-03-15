import Foundation
import simd

public struct Segment: Sendable, Hashable {
    public let start: SIMD3<Float>
    public let end: SIMD3<Float>
    public let width: Float
    public let layerHeight: Float
    public let moveType: MoveType
    public let filamentIndex: Int
    public let layerIndex: Int

    public init(
        start: SIMD3<Float>,
        end: SIMD3<Float>,
        width: Float,
        layerHeight: Float,
        moveType: MoveType,
        filamentIndex: Int,
        layerIndex: Int
    ) {
        self.start = start
        self.end = end
        self.width = width
        self.layerHeight = layerHeight
        self.moveType = moveType
        self.filamentIndex = filamentIndex
        self.layerIndex = layerIndex
    }

    public var length: Float {
        simd_length(end - start)
    }
}
