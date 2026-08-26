//
//  MuscleBodyScene.swift
//  Cinder
//
//  Scene + coloring for the continuous SDF body (see MuscleBodyGeometry).
//  The whole figure is ONE mesh with per-vertex colors: muscle regions tint
//  graphite → rose → deep blood red by intensity ("worked harder = darker
//  red"), and a surface shader adds an emissive glow wherever the surface is
//  red. Recoloring = swapping the color vertex source; positions/normals/
//  indices are built once and reused.
//

import SceneKit
import UIKit
import simd

/// Owns the scene graph + cached geometry sources; recolors in place.
final class MuscleBodyModel {
    let scene: SCNScene
    let bodyNode: SCNNode

    private let material: SCNMaterial
    private var mesh: BodyMesh?
    private var meshNode: SCNNode?
    private var positionSource: SCNGeometrySource?
    private var normalSource: SCNGeometrySource?
    private var element: SCNGeometryElement?

    // Desired state (kept even before the mesh finishes building).
    private var intensities: [MuscleGroup: Double] = [:]
    private var selected: Set<MuscleGroup> = []

    init() {
        scene = SCNScene()
        scene.background.contents = UIColor.clear

        bodyNode = SCNNode()
        scene.rootNode.addChildNode(bodyNode)

        material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor.white   // multiplied by vertex colors
        material.metalness.contents = 0.10
        material.roughness.contents = 0.48
        material.isDoubleSided = true
        // Emissive glow only where the surface is red (trained muscles).
        material.shaderModifiers = [.surface: """
        float redness = _surface.diffuse.r - max(_surface.diffuse.g, _surface.diffuse.b);
        _surface.emission.rgb += _surface.diffuse.rgb * clamp(redness * 1.5, 0.0, 0.55);
        """]

        MuscleBodyModel.addCamera(to: scene)
        MuscleBodyModel.addLights(to: scene)
        MuscleBodyModel.addGroundShadow(to: scene)
    }

    /// Soft radial contact shadow under the feet — grounds the figure.
    private static func addGroundShadow(to scene: SCNScene) {
        let size = 128
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let colors = [UIColor.black.withAlphaComponent(0.38).cgColor,
                          UIColor.black.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colors, locations: [0, 1]) else { return }
            let c = CGPoint(x: size / 2, y: size / 2)
            ctx.cgContext.drawRadialGradient(gradient, startCenter: c, startRadius: 0,
                                             endCenter: c, endRadius: CGFloat(size) / 2, options: [])
        }
        let plane = SCNPlane(width: 0.85, height: 0.55)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = image
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.eulerAngles.x = -.pi / 2
        node.position = SCNVector3(0, 0.004, 0.01)
        scene.rootNode.addChildNode(node)
    }

    /// Attach the built mesh (main thread). Applies whatever state arrived early.
    func attach(mesh: BodyMesh) {
        guard meshNode == nil else { return }
        self.mesh = mesh

        func source(_ data: [SIMD3<Float>], _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
            data.withUnsafeBufferPointer { buf in
                SCNGeometrySource(
                    data: Data(buffer: buf), semantic: semantic,
                    vectorCount: data.count, usesFloatComponents: true,
                    componentsPerVector: 3, bytesPerComponent: 4,
                    dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
            }
        }
        positionSource = source(mesh.positions, .vertex)
        normalSource = source(mesh.normals, .normal)
        element = SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)

        let node = SCNNode()
        meshNode = node
        bodyNode.addChildNode(node)
        rebuildGeometry()
    }

    var isMeshAttached: Bool { meshNode != nil }

    /// Update colors; safe to call anytime (state is replayed after attach).
    func apply(intensities: [MuscleGroup: Double], selected: Set<MuscleGroup>) {
        self.intensities = intensities
        self.selected = selected
        guard meshNode != nil else { return }
        rebuildGeometry()
    }

    /// MuscleGroup for a hit-test face, or nil for base body.
    func muscle(atFace faceIndex: Int) -> MuscleGroup? {
        guard let mesh, faceIndex * 3 + 2 < mesh.indices.count else { return nil }
        let all = MuscleGroup.allCases
        // Majority vote across the triangle's vertices.
        var counts: [Int16: Int] = [:]
        for i in 0..<3 {
            let v = Int(mesh.indices[faceIndex * 3 + i])
            let id = mesh.muscleIds[v]
            if id >= 0 && mesh.muscleBlend[v] > 0.35 { counts[id, default: 0] += 1 }
        }
        guard let best = counts.max(by: { $0.value < $1.value }), best.value >= 2,
              Int(best.key) < all.count else { return nil }
        return all[Int(best.key)]
    }

    // MARK: - Coloring

    private func rebuildGeometry() {
        guard let mesh, let positionSource, let normalSource, let element,
              let meshNode else { return }

        var colors = [SIMD4<Float>](repeating: baseColor, count: mesh.positions.count)
        let all = MuscleGroup.allCases

        // Precompute per-group target colors.
        var groupColor = [SIMD4<Float>](repeating: regionBaseColor, count: all.count)
        for (i, group) in all.enumerated() {
            let t = Float(min(max(intensities[group] ?? 0, 0), 1))
            var c = t > 0.001 ? MuscleBodyModel.rampSIMD(t) : regionBaseColor
            if selected.contains(group) {
                c = simd_mix(c, SIMD4(1.0, 0.15, 0.12, 1), SIMD4(repeating: 0.30))
            }
            groupColor[i] = c
        }

        for v in 0..<mesh.positions.count {
            let id = mesh.muscleIds[v]
            guard id >= 0 else { continue }
            let blend = mesh.muscleBlend[v]
            colors[v] = simd_mix(baseColor, groupColor[Int(id)], SIMD4(repeating: blend))
        }

        let colorSource = colors.withUnsafeBufferPointer { buf in
            SCNGeometrySource(
                data: Data(buffer: buf), semantic: .color,
                vectorCount: colors.count, usesFloatComponents: true,
                componentsPerVector: 4, bytesPerComponent: 4,
                dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride)
        }

        let geometry = SCNGeometry(sources: [positionSource, normalSource, colorSource],
                                   elements: [element])
        geometry.materials = [material]
        meshNode.geometry = geometry
    }

    /// Base body: near-black graphite. Regions idle slightly lighter so the
    /// anatomy reads even untrained.
    private let baseColor = SIMD4<Float>(0.110, 0.110, 0.125, 1)
    private let regionBaseColor = SIMD4<Float>(0.185, 0.185, 0.205, 1)

    // MARK: - Ramp (shared with chips)

    /// Graphite → soft rose → deep blood red as intensity rises.
    static func rampColor(_ t: CGFloat) -> UIColor {
        guard t > 0.001 else { return UIColor(white: 0.24, alpha: 1) }
        return UIColor(hue: 0.995, saturation: 0.30 + 0.70 * t,
                       brightness: 0.88 - 0.42 * t, alpha: 1)
    }

    private static func rampSIMD(_ t: Float) -> SIMD4<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rampColor(CGFloat(t)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4(Float(r), Float(g), Float(b), 1)
    }

    // MARK: - Camera & lights

    private static func addCamera(to scene: SCNScene) {
        let camera = SCNCamera()
        camera.fieldOfView = 36
        camera.zNear = 0.1
        camera.zFar = 20
        let node = SCNNode()
        node.camera = camera
        node.position = SCNVector3(0, 1.02, 2.9)
        node.look(at: SCNVector3(0, 0.98, 0))
        scene.rootNode.addChildNode(node)
    }

    private static func addLights(to scene: SCNScene) {
        func light(_ type: SCNLight.LightType, intensity: CGFloat,
                   color: UIColor = .white, position: SCNVector3? = nil) -> SCNNode {
            let l = SCNLight()
            l.type = type
            l.intensity = intensity
            l.color = color
            let n = SCNNode()
            n.light = l
            if let p = position { n.position = p; n.look(at: SCNVector3(0, 1.0, 0)) }
            return n
        }
        scene.rootNode.addChildNode(
            light(.directional, intensity: 900, position: SCNVector3(-1.6, 2.6, 2.2)))
        scene.rootNode.addChildNode(
            light(.directional, intensity: 320,
                  color: UIColor(red: 0.82, green: 0.87, blue: 1.0, alpha: 1),
                  position: SCNVector3(1.8, 1.4, 1.6)))
        scene.rootNode.addChildNode(
            light(.directional, intensity: 650,
                  color: UIColor(red: 0.75, green: 0.82, blue: 1.0, alpha: 1),
                  position: SCNVector3(0.4, 2.4, -2.6)))
        scene.rootNode.addChildNode(light(.ambient, intensity: 180))
    }
}
