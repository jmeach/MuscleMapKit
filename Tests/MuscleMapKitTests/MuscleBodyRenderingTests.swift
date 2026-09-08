import Metal
import RealityKit
import XCTest
@testable import MuscleMapKit

final class MuscleBodyRenderingTests: XCTestCase {

    private func bakedMesh() throws -> BodyMesh {
        try MuscleBodyMesh.loadBakedBody()
    }

    // MARK: - Bounds

    func testBakedBoundsAreValidAndStandOnTheOrigin() throws {
        let bounds = try bakedMesh().bounds
        XCTAssertGreaterThan(bounds.extent.y, 1.0, "body height should be about a standing figure")
        XCTAssertGreaterThan(bounds.extent.x, 0.2)
        XCTAssertGreaterThan(bounds.extent.z, 0.1)
        XCTAssertEqual(bounds.min.y, 0, accuracy: 0.02, "feet should sit on y = 0")
        XCTAssertGreaterThan(bounds.max.y, 1.5)
        XCTAssertNotEqual(bounds.center, SIMD3<Float>.zero)
        XCTAssertEqual(bounds.center.y, bounds.extent.y * 0.5, accuracy: 0.02)
        XCTAssertGreaterThan(bounds.yawRadiusAboutOrigin, bounds.extent.x * 0.4)
        XCTAssertEqual(bounds.corners.count, 8)
    }

    func testFramingLookAtIsTheMeshBoundsCenter() throws {
        let bounds = try bakedMesh().bounds
        let framing = MuscleBodyFraming.fit(bounds: bounds)
        XCTAssertEqual(framing.lookAt.x, bounds.center.x, accuracy: 1e-5)
        XCTAssertEqual(framing.lookAt.y, bounds.center.y, accuracy: 1e-5)
        XCTAssertEqual(framing.lookAt.z, bounds.center.z, accuracy: 1e-5)
        XCTAssertGreaterThan(framing.lookAt.y, 0.5)
        XCTAssertNotEqual(framing.lookAt.y, 0, accuracy: 0.1)
        XCTAssertEqual(framing.fieldOfViewDegrees, 36, accuracy: 0.01)
        XCTAssertGreaterThan(framing.distance, 1.5)
        XCTAssertLessThan(framing.distance, 5.0)
        XCTAssertEqual(framing.cameraPosition.x, framing.lookAt.x, accuracy: 1e-5)
        XCTAssertEqual(framing.cameraPosition.y, framing.lookAt.y, accuracy: 1e-5)
        XCTAssertGreaterThan(framing.cameraPosition.z, framing.lookAt.z)
    }

    func testFramingContainsAllBoundsCorners() throws {
        let bounds = try bakedMesh().bounds
        let framing = MuscleBodyFraming.fit(bounds: bounds)
        XCTAssertTrue(framing.containsBounds(bounds), "front view should contain the full AABB")
    }

    func testFramingContainsCornersForCardinalYaw() throws {
        let bounds = try bakedMesh().bounds
        let framing = MuscleBodyFraming.fit(bounds: bounds)
        for yaw in [Float(0), .pi / 2, .pi, 3 * .pi / 2] {
            XCTAssertTrue(
                framing.containsBounds(bounds, yaw: yaw),
                "yaw \(yaw) clipped a bounding-box corner"
            )
        }
    }

    func testFramingIsTighterThanAHugeMargin() throws {
        let bounds = try bakedMesh().bounds
        let framing = MuscleBodyFraming.fit(bounds: bounds)
        let head = SIMD3(bounds.center.x, bounds.max.y, bounds.center.z)
        let feet = SIMD3(bounds.center.x, bounds.min.y, bounds.center.z)
        let headNDC = framing.projectedNDC(head)
        let feetNDC = framing.projectedNDC(feet)
        XCTAssertGreaterThan(abs(headNDC.y), 0.75, "head should sit near the top of the frame")
        XCTAssertGreaterThan(abs(feetNDC.y), 0.75, "feet should sit near the bottom of the frame")
        XCTAssertLessThan(abs(headNDC.y), 1.0)
        XCTAssertLessThan(abs(feetNDC.y), 1.0)
    }

    // MARK: - Vertex colors

    func testVertexColorCountMatchesVertexCount() throws {
        let mesh = try bakedMesh()
        let colors = MuscleBodyMaterial.vertexColors(
            mesh: mesh,
            intensities: [:],
            selected: [],
            style: .dark
        )
        XCTAssertEqual(colors.count, mesh.vertexCount)
    }

    func testUnclassifiedVerticesStayBaseGraphite() throws {
        let mesh = try bakedMesh()
        let colors = MuscleBodyMaterial.vertexColors(
            mesh: mesh,
            intensities: [.chest: 1],
            selected: [],
            style: .dark
        )
        var sawBase = false
        for i in 0..<mesh.vertexCount where mesh.muscleIds[i] < 0 {
            XCTAssertEqual(colors[i].x, MuscleBodyStyle.dark.baseColor.x, accuracy: 0.001)
            XCTAssertEqual(colors[i].y, MuscleBodyStyle.dark.baseColor.y, accuracy: 0.001)
            XCTAssertEqual(colors[i].z, MuscleBodyStyle.dark.baseColor.z, accuracy: 0.001)
            sawBase = true
        }
        XCTAssertTrue(sawBase)
    }

    func testIdleMuscleVerticesUseIdleRegionColor() throws {
        let mesh = try bakedMesh()
        let colors = MuscleBodyMaterial.vertexColors(
            mesh: mesh,
            intensities: [:],
            selected: [],
            style: .dark
        )
        var sawIdle = false
        for i in 0..<mesh.vertexCount {
            guard mesh.muscleIds[i] >= 0, mesh.muscleBlend[i] > 0.95 else { continue }
            XCTAssertEqual(colors[i].x, MuscleBodyStyle.dark.idleRegionColor.x, accuracy: 0.02)
            XCTAssertEqual(colors[i].y, MuscleBodyStyle.dark.idleRegionColor.y, accuracy: 0.02)
            sawIdle = true
            break
        }
        XCTAssertTrue(sawIdle)
    }

    func testActivatedMuscleVerticesInterpolateTowardIntensityColor() throws {
        let mesh = try bakedMesh()
        let style = MuscleBodyStyle.dark
        let colors = MuscleBodyMaterial.vertexColors(
            mesh: mesh,
            intensities: [.chest: 1.0],
            selected: [],
            style: style
        )
        let target = style.color(for: 1.0, selected: false)
        var sawWorked = false
        for i in 0..<mesh.vertexCount {
            guard mesh.muscleIds[i] == Int16(MuscleGroup.chest.meshIndex),
                  mesh.muscleBlend[i] > 0.8 else { continue }
            XCTAssertGreaterThan(colors[i].x, colors[i].y)
            XCTAssertEqual(colors[i].x, target.x, accuracy: 0.15)
            sawWorked = true
        }
        XCTAssertTrue(sawWorked)
    }

    func testSelectionBoostShiftsVertexColorTowardSelectedTint() throws {
        let mesh = try bakedMesh()
        let idle = MuscleBodyMaterial.vertexColors(
            mesh: mesh,
            intensities: [.chest: 0.4],
            selected: [],
            style: .dark
        )
        let selected = MuscleBodyMaterial.vertexColors(
            mesh: mesh,
            intensities: [.chest: 0.4],
            selected: [.chest],
            style: .dark
        )
        var compared = false
        for i in 0..<mesh.vertexCount {
            guard mesh.muscleIds[i] == Int16(MuscleGroup.chest.meshIndex),
                  mesh.muscleBlend[i] > 0.8 else { continue }
            XCTAssertGreaterThan(selected[i].x, idle[i].x - 0.001)
            compared = true
            break
        }
        XCTAssertTrue(compared)
    }

    @MainActor
    func testColorBufferRewriteLeavesGeometryCountsUnchanged() throws {
        let mesh = try bakedMesh()
        let initial = MuscleBodyMaterial.vertexColors(
            mesh: mesh,
            intensities: [.chest: 0.2],
            selected: [],
            style: .dark
        )
        let lowLevel = try MuscleBodyEntity.makeLowLevelMesh(from: mesh, colors: initial)
        var positionCount = 0
        var indexCount = 0
        lowLevel.withUnsafeBytes(bufferIndex: MuscleBodyEntity.geometryBufferIndex) { raw in
            positionCount = raw.bindMemory(to: MuscleBodyEntity.GeometryVertex.self).count
        }
        lowLevel.withUnsafeIndices { raw in
            indexCount = raw.bindMemory(to: UInt32.self).count
        }

        let updated = MuscleBodyMaterial.vertexColors(
            mesh: mesh,
            intensities: [.chest: 1, .quads: 0.7],
            selected: [.chest],
            style: .dark
        )
        lowLevel.replaceUnsafeMutableBytes(bufferIndex: MuscleBodyEntity.colorBufferIndex) { raw in
            let buffer = raw.bindMemory(to: SIMD4<Float>.self)
            for i in 0..<min(buffer.count, updated.count) {
                buffer[i] = updated[i]
            }
        }

        var positionCountAfter = 0
        var indexCountAfter = 0
        var colorCount = 0
        lowLevel.withUnsafeBytes(bufferIndex: MuscleBodyEntity.geometryBufferIndex) { raw in
            positionCountAfter = raw.bindMemory(to: MuscleBodyEntity.GeometryVertex.self).count
        }
        lowLevel.withUnsafeIndices { raw in
            indexCountAfter = raw.bindMemory(to: UInt32.self).count
        }
        lowLevel.withUnsafeBytes(bufferIndex: MuscleBodyEntity.colorBufferIndex) { raw in
            colorCount = raw.bindMemory(to: SIMD4<Float>.self).count
        }
        XCTAssertEqual(positionCountAfter, positionCount)
        XCTAssertEqual(indexCountAfter, indexCount)
        XCTAssertEqual(positionCount, mesh.vertexCount)
        XCTAssertEqual(indexCount, mesh.indices.count)
        XCTAssertEqual(colorCount, mesh.vertexCount)
    }

    // MARK: - Metal

    func testMetalLibraryLoadsFromThePackageBundle() throws {
        let library = try MuscleBodyMaterial.loadMetalLibrary()
        XCTAssertNotNil(library)
    }

    func testSurfaceShaderFunctionExistsInThePackageLibrary() throws {
        let library = try MuscleBodyMaterial.loadMetalLibrary()
        let function = library.makeFunction(name: MuscleBodyMaterial.surfaceShaderName)
        XCTAssertNotNil(
            function,
            "visible shader \(MuscleBodyMaterial.surfaceShaderName) missing from MuscleMapKit metallib"
        )
    }

    @MainActor
    func testCustomMaterialCanBeConstructedFromThePackageShader() throws {
        let material = try MuscleBodyMaterial.makeSurfaceMaterial()
        XCTAssertEqual(material.lightingModel, .unlit)
        XCTAssertEqual(material.roughness.scale, MuscleBodyMaterial.roughness, accuracy: 0.001)
        XCTAssertEqual(material.metallic.scale, MuscleBodyMaterial.metallic, accuracy: 0.001)
        XCTAssertEqual(material.faceCulling, .none)
    }

    @MainActor
    func testEntityAttachesOnceAndRecolorsWithoutRebuildingGeometry() throws {
        let entity = MuscleBodyEntity()
        try entity.attachCachedMesh(
            intensities: [.chest: 1.0, .triceps: 0.6],
            selected: [],
            style: .dark
        )
        XCTAssertTrue(entity.isMeshAttached)
        XCTAssertNotNil(entity.lowLevelMesh)
        XCTAssertNotNil(entity.meshBounds)
        XCTAssertEqual(entity.framingTarget.position.y, entity.meshBounds?.center.y ?? 0, accuracy: 0.001)
        XCTAssertNotNil(entity.body.components[ModelComponent.self])

        let positions: Int = {
            var count = 0
            entity.lowLevelMesh?.withUnsafeBytes(bufferIndex: MuscleBodyEntity.geometryBufferIndex) { raw in
                count = raw.bindMemory(to: MuscleBodyEntity.GeometryVertex.self).count
            }
            return count
        }()

        entity.apply(intensities: [.chest: 0.4, .quads: 1.0], selected: [.quads], style: .dark)
        var positionsAfter = 0
        entity.lowLevelMesh?.withUnsafeBytes(bufferIndex: MuscleBodyEntity.geometryBufferIndex) { raw in
            positionsAfter = raw.bindMemory(to: MuscleBodyEntity.GeometryVertex.self).count
        }
        XCTAssertEqual(positionsAfter, positions)
        XCTAssertTrue(entity.body.components[ModelComponent.self] != nil)
    }
}
