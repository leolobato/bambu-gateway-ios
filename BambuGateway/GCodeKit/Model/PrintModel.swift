import Foundation
import simd

public struct BuildPlate: Sendable, Hashable {
    public let minX: Float
    public let maxX: Float
    public let minY: Float
    public let maxY: Float
    public let z: Float

    public init(minX: Float, maxX: Float, minY: Float, maxY: Float, z: Float = 0) {
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
        self.z = z
    }

    public var width: Float {
        max(maxX - minX, 0)
    }

    public var depth: Float {
        max(maxY - minY, 0)
    }

    public var center: SIMD3<Float> {
        SIMD3<Float>((minX + maxX) * 0.5, (minY + maxY) * 0.5, z)
    }
}

public struct PrintLayer: Sendable, Hashable {
    public let index: Int
    public let z: Float
    public let segments: [Segment]

    public init(index: Int, z: Float, segments: [Segment]) {
        self.index = index
        self.z = z
        self.segments = segments
    }
}

public struct PrintModel: Sendable {
    public let segments: [Segment]
    public let buildPlate: BuildPlate?

    public init(segments: [Segment], buildPlate: BuildPlate? = nil) {
        self.segments = segments
        self.buildPlate = buildPlate
    }

    public var isEmpty: Bool {
        segments.isEmpty
    }

    public var layerCount: Int {
        Set(segments.map(\.layerIndex)).count
    }

    public var layers: [PrintLayer] {
        let grouped = Dictionary(grouping: segments, by: \.layerIndex)
        return grouped
            .keys
            .sorted()
            .map { index in
                let layerSegments = grouped[index] ?? []
                let z = layerSegments.first?.start.z ?? 0
                return PrintLayer(index: index, z: z, segments: layerSegments)
            }
    }
}
