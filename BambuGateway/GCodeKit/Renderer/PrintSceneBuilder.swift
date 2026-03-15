import Foundation
import SceneKit
import simd

#if canImport(UIKit)
import UIKit
private typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
private typealias PlatformColor = NSColor
#endif

public struct PrintSceneBuilder {
    private static let defaultCameraNodeName = "preview_camera"
    private static let defaultCameraTargetNodeName = "preview_camera_target"

    public init() {}

    public func buildScene(from model: PrintModel) -> SCNScene {
        let scene = SCNScene()
        let root = scene.rootNode

        // First pass: count segments per group for capacity pre-reservation
        var counts: [GroupKey: Int] = [:]
        counts.reserveCapacity(8)
        for segment in model.segments {
            if segment.length <= 0.0001 { continue }
            let key = GroupKey(filament: segment.filamentIndex, moveType: segment.moveType)
            counts[key, default: 0] += 1
        }

        // Allocate accumulators with reserved capacity
        var grouped: [GroupKey: MeshAccumulator] = [:]
        grouped.reserveCapacity(counts.count)
        for (key, count) in counts {
            grouped[key] = MeshAccumulator(estimatedSegments: count)
        }

        // Second pass: fill geometry (in-place mutation, no CoW copies)
        for segment in model.segments {
            if segment.length <= 0.0001 { continue }
            let key = GroupKey(filament: segment.filamentIndex, moveType: segment.moveType)
            grouped[key]?.appendRibbon(for: segment)
        }

        for (key, mesh) in grouped {
            guard !mesh.positions.isEmpty else {
                continue
            }

            let geometry = makeGeometry(from: mesh)
            let material = SCNMaterial()
            material.diffuse.contents = color(for: key)
            material.lightingModel = .blinn
            material.isDoubleSided = false
            material.transparency = key.moveType == .support ? 0.5 : 1.0

            geometry.materials = [material]

            let node = SCNNode(geometry: geometry)
            node.name = "filament_\(key.filament)_\(key.moveType.rawValue)"
            root.addChildNode(node)
        }

        let buildPlate = resolvedBuildPlate(for: model)
        addBuildPlate(buildPlate, to: root)
        addDefaultLighting(to: root)
        addCamera(to: root, buildPlate: buildPlate, model: model)

        return scene
    }

    private func makeGeometry(from mesh: MeshAccumulator) -> SCNGeometry {
        let vertexData = Data(fromArray: mesh.positions)
        let normalData = Data(fromArray: mesh.normals)
        let indexData = Data(fromArray: mesh.indices)

        let vertices = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: mesh.positions.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )

        let normals = SCNGeometrySource(
            data: normalData,
            semantic: .normal,
            vectorCount: mesh.normals.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )

        let elements = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: mesh.indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        return SCNGeometry(sources: [vertices, normals], elements: [elements])
    }

    private func color(for key: GroupKey) -> PlatformColor {
        if key.moveType == .support {
            return PlatformColor(red: 0.38, green: 0.58, blue: 0.92, alpha: 0.55)
        }

        let palette: [PlatformColor] = [
            PlatformColor(red: 0.88, green: 0.27, blue: 0.24, alpha: 1),
            PlatformColor(red: 0.16, green: 0.65, blue: 0.36, alpha: 1),
            PlatformColor(red: 0.94, green: 0.70, blue: 0.18, alpha: 1),
            PlatformColor(red: 0.30, green: 0.39, blue: 0.93, alpha: 1),
            PlatformColor(red: 0.92, green: 0.45, blue: 0.16, alpha: 1),
            PlatformColor(red: 0.12, green: 0.62, blue: 0.74, alpha: 1)
        ]

        let index = abs(key.filament) % palette.count
        return palette[index]
    }

    private func addDefaultLighting(to root: SCNNode) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 300

        let ambientNode = SCNNode()
        ambientNode.light = ambient
        root.addChildNode(ambientNode)

        // Key light — directional, from upper-front-right
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 800

        let keyNode = SCNNode()
        keyNode.light = keyLight
        // Point down and towards the model
        keyNode.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 6, 0)
        root.addChildNode(keyNode)

        // Fill light — softer, from the opposite side
        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.intensity = 400

        let fillNode = SCNNode()
        fillNode.light = fillLight
        fillNode.eulerAngles = SCNVector3(-Float.pi / 4, -Float.pi / 3, 0)
        root.addChildNode(fillNode)
    }

    private func addBuildPlate(_ buildPlate: BuildPlate, to root: SCNNode) {
        let plateGeometry = SCNBox(
            width: CGFloat(buildPlate.width),
            height: CGFloat(buildPlate.depth),
            length: 1.2,
            chamferRadius: 1.5
        )

        let sideMaterial = SCNMaterial()
        sideMaterial.diffuse.contents = PlatformColor(red: 0.20, green: 0.22, blue: 0.25, alpha: 1)
        sideMaterial.lightingModel = .blinn
        sideMaterial.roughness.contents = 0.95

        let topMaterial = SCNMaterial()
        topMaterial.diffuse.contents = PlatformColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1)
        topMaterial.lightingModel = .blinn
        topMaterial.roughness.contents = 1.0

        plateGeometry.materials = [
            sideMaterial,
            sideMaterial,
            topMaterial,
            sideMaterial,
            sideMaterial,
            sideMaterial
        ]

        let plateNode = SCNNode(geometry: plateGeometry)
        plateNode.name = "build_plate"
        plateNode.position = SCNVector3(buildPlate.center.x, buildPlate.center.y, buildPlate.z - 0.6)
        root.addChildNode(plateNode)

        let frameGeometry = SCNBox(
            width: CGFloat(buildPlate.width + 2),
            height: CGFloat(buildPlate.depth + 2),
            length: 0.3,
            chamferRadius: 1.2
        )
        let frameMaterial = SCNMaterial()
        frameMaterial.diffuse.contents = PlatformColor(red: 0.28, green: 0.30, blue: 0.34, alpha: 1)
        frameMaterial.lightingModel = .blinn
        frameGeometry.materials = Array(repeating: frameMaterial, count: 6)

        let frameNode = SCNNode(geometry: frameGeometry)
        frameNode.name = "build_plate_frame"
        frameNode.position = SCNVector3(buildPlate.center.x, buildPlate.center.y, buildPlate.z + 0.16)
        root.addChildNode(frameNode)

        addBuildPlateGrid(buildPlate, to: root)
    }

    private func addBuildPlateGrid(_ buildPlate: BuildPlate, to root: SCNNode) {
        let gridZ = buildPlate.z + 0.63
        let minorSpacing: Float = 10
        let majorSpacing: Float = 50

        let minorMaterial = SCNMaterial()
        minorMaterial.diffuse.contents = PlatformColor(red: 0.32, green: 0.34, blue: 0.38, alpha: 0.45)
        minorMaterial.lightingModel = .constant

        let majorMaterial = SCNMaterial()
        majorMaterial.diffuse.contents = PlatformColor(red: 0.42, green: 0.45, blue: 0.50, alpha: 0.72)
        majorMaterial.lightingModel = .constant

        let firstX = ceil(buildPlate.minX / minorSpacing) * minorSpacing
        let firstY = ceil(buildPlate.minY / minorSpacing) * minorSpacing

        var x = firstX
        while x <= buildPlate.maxX {
            let isMajor = abs(x.truncatingRemainder(dividingBy: majorSpacing)) < 0.001
            let geometry = SCNBox(
                width: CGFloat(isMajor ? 0.24 : 0.12),
                height: CGFloat(buildPlate.depth),
                length: 0.02,
                chamferRadius: 0
            )
            geometry.materials = [isMajor ? majorMaterial : minorMaterial]

            let node = SCNNode(geometry: geometry)
            node.position = SCNVector3(x, buildPlate.center.y, gridZ)
            root.addChildNode(node)
            x += minorSpacing
        }

        var y = firstY
        while y <= buildPlate.maxY {
            let isMajor = abs(y.truncatingRemainder(dividingBy: majorSpacing)) < 0.001
            let geometry = SCNBox(
                width: CGFloat(buildPlate.width),
                height: CGFloat(isMajor ? 0.24 : 0.12),
                length: 0.02,
                chamferRadius: 0
            )
            geometry.materials = [isMajor ? majorMaterial : minorMaterial]

            let node = SCNNode(geometry: geometry)
            node.position = SCNVector3(buildPlate.center.x, y, gridZ)
            root.addChildNode(node)
            y += minorSpacing
        }
    }

    private func addCamera(to root: SCNNode, buildPlate: BuildPlate, model: PrintModel) {
        let printTopZ = model.segments.reduce(buildPlate.z) { current, segment in
            max(current, segment.start.z, segment.end.z + segment.layerHeight)
        }
        let printHeight = max(printTopZ - buildPlate.z, 5)
        let target = SIMD3<Float>(
            buildPlate.center.x,
            buildPlate.center.y,
            buildPlate.z + printHeight * 0.22
        )

        let targetNode = SCNNode()
        targetNode.name = Self.defaultCameraTargetNodeName
        targetNode.position = SCNVector3(target.x, target.y, target.z)
        root.addChildNode(targetNode)

        let camera = SCNCamera()
        camera.zNear = 0.1
        camera.zFar = 100_000
        camera.fieldOfView = 42
        camera.projectionDirection = .vertical

        let cameraNode = SCNNode()
        cameraNode.name = Self.defaultCameraNodeName
        cameraNode.camera = camera

        let framingRadius = simd_length(
            SIMD3<Float>(buildPlate.width * 0.5, buildPlate.depth * 0.5, printHeight * 0.7)
        )
        let halfFOV = Float(camera.fieldOfView) * Float.pi / 360
        let distance = max(framingRadius / sinf(halfFOV), 170)
        let isometricDirection = simd_normalize(SIMD3<Float>(0.72, -1.18, 1.22))
        let position = target + isometricDirection * distance

        cameraNode.position = SCNVector3(position.x, position.y, position.z)
        cameraNode.look(
            at: SCNVector3(target.x, target.y, target.z),
            up: SCNVector3(0, 0, 1),
            localFront: SCNVector3(0, 0, -1)
        )
        root.addChildNode(cameraNode)
    }

    private func resolvedBuildPlate(for model: PrintModel) -> BuildPlate {
        if let buildPlate = model.buildPlate,
           buildPlate.width > 0.1,
           buildPlate.depth > 0.1 {
            return buildPlate
        }

        guard let firstSegment = model.segments.first else {
            return BuildPlate(minX: -110, maxX: 110, minY: -110, maxY: 110)
        }

        let margin: Float = 12
        var minX = min(firstSegment.start.x, firstSegment.end.x) - max(firstSegment.width * 0.5, margin)
        var maxX = max(firstSegment.start.x, firstSegment.end.x) + max(firstSegment.width * 0.5, margin)
        var minY = min(firstSegment.start.y, firstSegment.end.y) - max(firstSegment.width * 0.5, margin)
        var maxY = max(firstSegment.start.y, firstSegment.end.y) + max(firstSegment.width * 0.5, margin)

        for segment in model.segments.dropFirst() {
            let padding = max(segment.width * 0.5, 1)
            minX = min(minX, min(segment.start.x, segment.end.x) - padding)
            maxX = max(maxX, max(segment.start.x, segment.end.x) + padding)
            minY = min(minY, min(segment.start.y, segment.end.y) - padding)
            maxY = max(maxY, max(segment.start.y, segment.end.y) + padding)
        }

        return BuildPlate(
            minX: minX - margin,
            maxX: maxX + margin,
            minY: minY - margin,
            maxY: maxY + margin
        )
    }
}

private struct GroupKey: Hashable {
    let filament: Int
    let moveType: MoveType
}

private struct MeshAccumulator {
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var indices: [UInt32]

    init(estimatedSegments: Int = 0) {
        // Each segment produces 5 quads × 4 vertices = 20 positions/normals
        // Each segment produces 5 quads × 6 indices = 30 indices
        let vertexCount = estimatedSegments * 20
        let indexCount = estimatedSegments * 30
        positions = []
        normals = []
        indices = []
        positions.reserveCapacity(vertexCount)
        normals.reserveCapacity(vertexCount)
        indices.reserveCapacity(indexCount)
    }

    mutating func appendRibbon(for segment: Segment) {
        let start = segment.start
        let end = segment.end
        let axis = end - start
        let length = simd_length(axis)

        guard length > 0.0001 else {
            return
        }

        let direction = axis / length
        let up = SIMD3<Float>(0, 0, 1)
        var lateral = simd_cross(up, direction)
        if simd_length(lateral) < 0.0001 {
            lateral = simd_cross(SIMD3<Float>(0, 1, 0), direction)
        }

        lateral = simd_normalize(lateral) * (max(segment.width, 0.01) * 0.5)
        let vertical = SIMD3<Float>(0, 0, max(segment.layerHeight, 0.01))

        let s0 = start - lateral
        let s1 = start + lateral
        let e0 = end - lateral
        let e1 = end + lateral

        let s0t = s0 + vertical
        let s1t = s1 + vertical
        let e0t = e0 + vertical
        let e1t = e1 + vertical

        appendQuad(a: s0t, b: s1t, c: e1t, d: e0t, normal: SIMD3<Float>(0, 0, 1))
        appendQuad(a: s0, b: e0, c: e0t, d: s0t, normal: simd_normalize(-lateral))
        appendQuad(a: s1, b: e1, c: e1t, d: s1t, normal: simd_normalize(lateral))
        appendQuad(a: s0, b: s1, c: s1t, d: s0t, normal: simd_normalize(-direction))
        appendQuad(a: e0, b: e1, c: e1t, d: e0t, normal: simd_normalize(direction))
    }

    private mutating func appendQuad(
        a: SIMD3<Float>,
        b: SIMD3<Float>,
        c: SIMD3<Float>,
        d: SIMD3<Float>,
        normal: SIMD3<Float>
    ) {
        let baseIndex = UInt32(positions.count)
        positions.append(contentsOf: [a, b, c, d])
        normals.append(contentsOf: [normal, normal, normal, normal])

        indices.append(contentsOf: [
            baseIndex, baseIndex + 1, baseIndex + 2,
            baseIndex, baseIndex + 2, baseIndex + 3
        ])
    }
}

private extension Data {
    init<T>(fromArray values: [T]) {
        self = values.withUnsafeBufferPointer { pointer in
            Data(buffer: pointer)
        }
    }
}
