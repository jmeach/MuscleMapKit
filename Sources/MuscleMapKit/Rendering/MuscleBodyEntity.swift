import Foundation
import RealityKit
import simd
import UIKit

/// Owns one RealityKit body instance. Geometry is copied from the process-wide
/// CPU mesh once; later intensity/selection changes replace a tiny color ramp
/// texture without rebuilding the mesh.
@MainActor
final class MuscleBodyEntity {
    let root = Entity()
    let body = Entity()

    private var meshResource: MeshResource?
    private var cpuMesh: BodyMesh?
    private var lastIntensities: [MuscleGroup: Double] = [:]
    private var lastSelected: Set<MuscleGroup> = []
    private var lastStyle: MuscleBodyStyle?
    private var attached = false

    init() {
        root.addChild(body)
        MuscleBodyEntity.addLights(to: root)
        MuscleBodyEntity.addGroundShadow(to: root)
    }

    var isMeshAttached: Bool { attached }

    /// Build RealityKit resources from the cached CPU mesh. Safe to call once.
    func attachCachedMesh(
        intensities: [MuscleGroup: Double],
        selected: Set<MuscleGroup>,
        style: MuscleBodyStyle
    ) throws {
        guard !attached else {
            apply(intensities: intensities, selected: selected, style: style)
            return
        }

        let mesh = MuscleBodyMesh.shared()
        cpuMesh = mesh
        let clamped = MuscleIntensity.clamped(intensities)
        let texture = try MuscleBodyMaterial.makeRampTexture(
            intensities: clamped,
            selected: selected,
            style: style
        )
        let material = MuscleBodyMaterial.makeSurfaceMaterial(texture: texture)
        let lowLevel = try Self.makeLowLevelMesh(from: mesh)
        let resource = try MeshResource(from: lowLevel)
        body.components.set(ModelComponent(mesh: resource, materials: [material]))

        meshResource = resource
        lastIntensities = clamped
        lastSelected = selected
        lastStyle = style
        attached = true

        let attachedResource = resource
        Task { [weak body] in
            guard let body else { return }
            if let shape = try? await ShapeResource.generateStaticMesh(from: attachedResource) {
                var collision = CollisionComponent(shapes: [shape])
                collision.filter = .default
                body.components.set(collision)
                body.components.set(InputTargetComponent())
            }
        }
    }

    /// Recolor in place. Does not parse the mesh, regenerate collision, or rebuild the entity tree.
    func apply(
        intensities: [MuscleGroup: Double],
        selected: Set<MuscleGroup>,
        style: MuscleBodyStyle
    ) {
        let clamped = MuscleIntensity.clamped(intensities)
        guard attached else {
            lastIntensities = clamped
            lastSelected = selected
            lastStyle = style
            return
        }
        guard lastIntensities != clamped || lastSelected != selected || lastStyle != style else {
            return
        }
        lastIntensities = clamped
        lastSelected = selected
        lastStyle = style
        guard let texture = try? MuscleBodyMaterial.makeRampTexture(
            intensities: clamped,
            selected: selected,
            style: style
        ),
              var model = body.components[ModelComponent.self] else {
            return
        }
        model.materials = [MuscleBodyMaterial.makeSurfaceMaterial(texture: texture)]
        body.components.set(model)
    }

    func muscle(atFace faceIndex: Int) -> MuscleGroup? {
        cpuMesh?.muscle(atFace: faceIndex)
    }

    func muscle(nearestToLocal point: SIMD3<Float>) -> MuscleGroup? {
        cpuMesh?.muscle(nearestTo: point)
    }

    func pulseSelection() {
        let up = SIMD3<Float>(repeating: 1.025)
        let rest = SIMD3<Float>(repeating: 1)
        if #available(iOS 26.0, *) {
            Entity.animate(.easeOut(duration: 0.10), body: { [body] in
                body.scale = up
            }, completion: { [body] in
                Entity.animate(.easeOut(duration: 0.26), body: {
                    body.scale = rest
                })
            })
        } else {
            body.scale = rest
        }
    }

    // MARK: - Mesh construction

    private struct StaticVertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        var uv: SIMD2<Float>
    }

    private static func makeLowLevelMesh(from mesh: BodyMesh) throws -> LowLevelMesh {
        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexCapacity = mesh.positions.count
        descriptor.indexCapacity = mesh.indices.count
        descriptor.indexType = .uint32
        descriptor.vertexAttributes = [
            .init(semantic: .position, format: .float3, layoutIndex: 0, offset: MemoryLayout<StaticVertex>.offset(of: \.position)!),
            .init(semantic: .normal, format: .float3, layoutIndex: 0, offset: MemoryLayout<StaticVertex>.offset(of: \.normal)!),
            .init(semantic: .uv0, format: .float2, layoutIndex: 0, offset: MemoryLayout<StaticVertex>.offset(of: \.uv)!),
        ]
        descriptor.vertexLayouts = [
            .init(bufferIndex: 0, bufferStride: MemoryLayout<StaticVertex>.stride)
        ]

        let uvs = MuscleBodyMaterial.textureCoordinates(mesh: mesh)
        let lowLevel = try LowLevelMesh(descriptor: descriptor)
        lowLevel.replaceUnsafeMutableBytes(bufferIndex: 0) { raw in
            let vertices = raw.bindMemory(to: StaticVertex.self)
            for i in 0..<mesh.positions.count {
                vertices[i] = StaticVertex(
                    position: mesh.positions[i],
                    normal: mesh.normals[i],
                    uv: uvs[i]
                )
            }
        }
        lowLevel.replaceUnsafeMutableIndices { raw in
            let indices = raw.bindMemory(to: UInt32.self)
            for i in 0..<mesh.indices.count {
                indices[i] = UInt32(mesh.indices[i])
            }
        }

        let bounds = mesh.bounds
        let box = BoundingBox(min: bounds.min, max: bounds.max)
        lowLevel.parts.replaceAll([
            LowLevelMesh.Part(
                indexOffset: 0,
                indexCount: mesh.indices.count,
                topology: .triangle,
                materialIndex: 0,
                bounds: box
            )
        ])
        return lowLevel
    }

    // MARK: - Lights & shadow

    private static func addLights(to root: Entity) {
        func directional(intensity: Float, from: SIMD3<Float>) -> DirectionalLight {
            let light = DirectionalLight()
            light.light.intensity = intensity
            light.look(at: SIMD3(0, 1.0, 0), from: from, relativeTo: nil)
            return light
        }
        root.addChild(directional(intensity: 1200, from: SIMD3(-1.6, 2.6, 2.2)))
        root.addChild(directional(intensity: 420, from: SIMD3(1.8, 1.4, 1.6)))
        root.addChild(directional(intensity: 780, from: SIMD3(0.4, 2.4, -2.6)))
    }

    private static func addGroundShadow(to root: Entity) {
        let size = 128
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let colors = [
                UIColor.black.withAlphaComponent(0.38).cgColor,
                UIColor.black.withAlphaComponent(0).cgColor
            ] as CFArray
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            ) else { return }
            let c = CGPoint(x: size / 2, y: size / 2)
            ctx.cgContext.drawRadialGradient(
                gradient,
                startCenter: c,
                startRadius: 0,
                endCenter: c,
                endRadius: CGFloat(size) / 2,
                options: []
            )
        }
        guard let cgImage = image.cgImage,
              let texture = try? TextureResource.generate(
                from: cgImage,
                withName: "muscleMapGroundShadow",
                options: TextureResource.CreateOptions(semantic: .color)
              ) else {
            return
        }
        var material = UnlitMaterial()
        material.color = .init(texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        let plane = ModelEntity(
            mesh: .generatePlane(width: 0.85, depth: 0.55),
            materials: [material]
        )
        plane.position = SIMD3(0, 0.004, 0.01)
        root.addChild(plane)
    }
}
