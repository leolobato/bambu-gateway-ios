import Foundation
import SceneKit
import SwiftUI

#if canImport(UIKit)
import UIKit

public struct GCodePreviewView: UIViewRepresentable {
    private static let cameraNodeName = "preview_camera"
    private static let cameraTargetNodeName = "preview_camera_target"
    public let scene: SCNScene

    public init(scene: SCNScene) {
        self.scene = scene
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .systemBackground
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(withName: Self.cameraNodeName, recursively: true)
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.worldUp = SCNVector3(0, 0, 1)
        if let targetNode = scene.rootNode.childNode(withName: Self.cameraTargetNodeName, recursively: true) {
            view.defaultCameraController.target = targetNode.position
        }
        view.defaultCameraController.inertiaEnabled = true
        context.coordinator.currentScene = scene
        return view
    }

    public func updateUIView(_ scnView: SCNView, context: Context) {
        guard context.coordinator.currentScene !== scene else { return }
        context.coordinator.currentScene = scene
        scnView.scene = scene
        scnView.pointOfView = scene.rootNode.childNode(withName: Self.cameraNodeName, recursively: true)
        scnView.defaultCameraController.worldUp = SCNVector3(0, 0, 1)
        if let targetNode = scene.rootNode.childNode(withName: Self.cameraTargetNodeName, recursively: true) {
            scnView.defaultCameraController.target = targetNode.position
        }
    }

    public class Coordinator {
        weak var currentScene: SCNScene?
    }
}

#elseif canImport(AppKit)
import AppKit

public struct GCodePreviewView: NSViewRepresentable {
    private static let cameraNodeName = "preview_camera"
    private static let cameraTargetNodeName = "preview_camera_target"
    public let scene: SCNScene

    public init(scene: SCNScene) {
        self.scene = scene
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(withName: Self.cameraNodeName, recursively: true)
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.worldUp = SCNVector3(0, 0, 1)
        if let targetNode = scene.rootNode.childNode(withName: Self.cameraTargetNodeName, recursively: true) {
            view.defaultCameraController.target = targetNode.position
        }
        view.defaultCameraController.inertiaEnabled = true
        context.coordinator.currentScene = scene
        return view
    }

    public func updateNSView(_ scnView: SCNView, context: Context) {
        guard context.coordinator.currentScene !== scene else { return }
        context.coordinator.currentScene = scene
        scnView.scene = scene
        scnView.pointOfView = scene.rootNode.childNode(withName: Self.cameraNodeName, recursively: true)
        scnView.defaultCameraController.worldUp = SCNVector3(0, 0, 1)
        if let targetNode = scene.rootNode.childNode(withName: Self.cameraTargetNodeName, recursively: true) {
            scnView.defaultCameraController.target = targetNode.position
        }
    }

    public class Coordinator {
        weak var currentScene: SCNScene?
    }
}
#endif
