import Foundation
import RealityKit
import simd
import UIKit

/// Owns one RealityKit body instance. Geometry and collision are built once;
/// later intensity/selection changes rewrite only the per-vertex color buffer.
@MainActor
final class MuscleBodyEntity {
    let root = Entity()
    let body = Entity()
    /// Empty entity at the mesh visual center. Used as the camera look-at so
    /// framing is independent of the body's foot-origin transform.
    let framingTarget = Entity()

    private(set) var lowLevelMesh: LowLevelMesh?
    private var meshResource: MeshResource?
    private var cpuMesh: BodyMesh?
    private var lastIntensities: [MuscleGroup: Double] = [:]
    private var lastSelected: Set<MuscleGroup> = []
    private var lastStyle: MuscleBodyStyle?
    private var attached = false
    private var cameraEntity: PerspectiveCamera?
    private var framing: MuscleBodyFraming?
    /// Camera-distance magnification. `1` is the bounds-fitted full-body shot.
    private(set) var zoomScale: Float = 1

    init() {
        root.addChild(body)
        root.addChild(framingTarget)
        MuscleBodyEntity.addLights(to: root)
        MuscleBodyEntity.addGroundShadow(to: root)
    }

    var isMeshAttached: Bool { attached }

    var meshBounds: MeshBounds? { cpuMesh?.bounds }

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
        let colors = MuscleBodyMaterial.vertexColors(
            mesh: mesh,
            intensities: clamped,
            selected: selected,
            style: style
        )
        let material = try MuscleBodyMaterial.makeSurfaceMaterial()
        let lowLevel = try Self.makeLowLevelMesh(from: mesh, colors: colors)
        let resource = try MeshResource(from: lowLevel)
        body.components.set(ModelComponent(mesh: resource, materials: [material]))

        lowLevelMesh = lowLevel
        meshResource = resource
        lastIntensities = clamped
        lastSelected = selected
        lastStyle = style
        attached = true
        installCamera(bounds: mesh.bounds)

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
        guard let mesh = cpuMesh, let lowLevelMesh else { return }
        lowLevelMesh.replaceUnsafeMutableBytes(bufferIndex: Self.colorBufferIndex) { raw in
            let buffer = raw.bindMemory(to: SIMD4<Float>.self)
            MuscleBodyMaterial.writeVertexColors(
                to: buffer,
                mesh: mesh,
                intensities: clamped,
                selected: selected,
                style: style
            )
        }
    }

    func muscle(atFace faceIndex: Int) -> MuscleGroup? {
        cpuMesh?.muscle(atFace: faceIndex)
    }

    func muscle(nearestToLocal point: SIMD3<Float>) -> MuscleGroup? {
        cpuMesh?.muscle(nearestTo: point)
    }

    // MARK: - Camera

    func installCamera(bounds: MeshBounds) {
        let fitted = MuscleBodyFraming.fit(bounds: bounds)
        framing = fitted
        framingTarget.position = fitted.lookAt
        if cameraEntity == nil {
            let camera = PerspectiveCamera()
            camera.camera = PerspectiveCameraComponent(
                near: fitted.near,
                far: fitted.far,
                fieldOfViewInDegrees: fitted.fieldOfViewDegrees
            )
            root.addChild(camera)
            cameraEntity = camera
        }
        applyZoom(zoomScale)
    }

    /// Move the existing camera along its original view ray. Zoom deliberately
    /// does not scale `body`: entity scale would ride along with yaw, inertia,
    /// collision geometry, and the ground shadow.
    func applyZoom(_ scale: Float) {
        let clamped = MuscleBodyFraming.clampZoom(scale)
        zoomScale = clamped
        guard let framing, let cameraEntity else { return }
        cameraEntity.look(
            at: framing.lookAt,
            from: framing.cameraPosition(zoom: clamped),
            relativeTo: nil
        )
    }

    // MARK: - Mesh construction

    static let geometryBufferIndex = 0
    static let colorBufferIndex = 1

    struct GeometryVertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
    }

    static func makeLowLevelMesh(from mesh: BodyMesh, colors: [SIMD4<Float>]) throws -> LowLevelMesh {
        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexCapacity = mesh.positions.count
        descriptor.indexCapacity = mesh.indices.count
        descriptor.indexType = .uint32
        descriptor.vertexAttributes = [
            .init(
                semantic: .position,
                format: .float3,
                layoutIndex: geometryBufferIndex,
                offset: MemoryLayout<GeometryVertex>.offset(of: \.position)!
            ),
            .init(
                semantic: .normal,
                format: .float3,
                layoutIndex: geometryBufferIndex,
                offset: MemoryLayout<GeometryVertex>.offset(of: \.normal)!
            ),
            .init(
                semantic: .color,
                format: .float4,
                layoutIndex: colorBufferIndex,
                offset: 0
            ),
        ]
        descriptor.vertexLayouts = [
            .init(bufferIndex: geometryBufferIndex, bufferStride: MemoryLayout<GeometryVertex>.stride),
            .init(bufferIndex: colorBufferIndex, bufferStride: MemoryLayout<SIMD4<Float>>.stride),
        ]

        let lowLevel = try LowLevelMesh(descriptor: descriptor)
        lowLevel.replaceUnsafeMutableBytes(bufferIndex: geometryBufferIndex) { raw in
            let vertices = raw.bindMemory(to: GeometryVertex.self)
            for i in 0..<mesh.positions.count {
                vertices[i] = GeometryVertex(position: mesh.positions[i], normal: mesh.normals[i])
            }
        }
        lowLevel.replaceUnsafeMutableBytes(bufferIndex: colorBufferIndex) { raw in
            let buffer = raw.bindMemory(to: SIMD4<Float>.self)
            let count = min(buffer.count, colors.count)
            for i in 0..<count {
                buffer[i] = colors[i]
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
