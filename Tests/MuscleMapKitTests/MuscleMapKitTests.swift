import XCTest
@testable import MuscleMapKit

/// The mesh and the exercise table are the two things a consumer inherits
/// wholesale, so both are pinned here: a silently missing resource or a
/// renamed muscle would fail at runtime, in 3D, with no error.
final class MuscleMapKitTests: XCTestCase {

    // MARK: - Model

    func testSeventeenMuscleGroupsAreStable() {
        // The baked mesh stores a muscle id per vertex as an index into this
        // exact order. Reordering or inserting a case silently repaints the body.
        XCTAssertEqual(MuscleGroup.allCases.count, 17)
        XCTAssertEqual(MuscleGroup.allCases.map(\.rawValue), [
            "chest", "frontDelts", "sideDelts", "rearDelts", "biceps", "triceps",
            "forearms", "traps", "lats", "upperBack", "lowerBack", "abs",
            "obliques", "glutes", "quads", "hamstrings", "calves",
        ])
        for (index, group) in MuscleGroup.allCases.enumerated() {
            XCTAssertEqual(group.meshIndex, index, "\(group.rawValue) meshIndex drifted from allCases")
        }
    }

    func testEveryGroupHasAReadableName() {
        for group in MuscleGroup.allCases {
            XCTAssertFalse(group.displayName.isEmpty, "\(group.rawValue) has no display name")
        }
    }

    func testIntensityClampRejectsNonFiniteAndOutOfRangeValues() {
        XCTAssertEqual(MuscleIntensity.clamp(-2), 0)
        XCTAssertEqual(MuscleIntensity.clamp(0.4), 0.4)
        XCTAssertEqual(MuscleIntensity.clamp(2), 1)
        XCTAssertEqual(MuscleIntensity.clamp(.nan), 0)
        XCTAssertEqual(MuscleIntensity.clamp(.infinity), 0)
        let clamped = MuscleIntensity.clamped([.chest: 1.4, .quads: -0.2, .abs: .nan])
        XCTAssertEqual(clamped[.chest], 1)
        XCTAssertEqual(clamped[.quads], 0)
        XCTAssertEqual(clamped[.abs], 0)
        XCTAssertNil(clamped[.calves], "missing muscles stay untrained")
    }

    // MARK: - Resource

    func testBakedBodyMeshShipsInThePackageBundle() {
        let url = Bundle.module.url(forResource: "body", withExtension: "mesh")
        XCTAssertNotNil(url, "body.mesh missing from the package bundle")
        if let url, let data = try? Data(contentsOf: url) {
            XCTAssertGreaterThan(data.count, 1_000_000, "body.mesh looks truncated")
            XCTAssertEqual(String(bytes: data.prefix(4), encoding: .ascii), "CMB1",
                           "unexpected mesh header — the baker's format changed")
        }
    }

    func testBakedMeshParsesAndValidatesMuscleIds() throws {
        let mesh = try MuscleBodyMesh.loadBakedBody()
        XCTAssertGreaterThan(mesh.vertexCount, 1000)
        XCTAssertGreaterThan(mesh.triangleCount, 1000)
        XCTAssertEqual(mesh.positions.count, mesh.normals.count)
        XCTAssertEqual(mesh.positions.count, mesh.muscleIds.count)
        XCTAssertEqual(mesh.positions.count, mesh.muscleBlend.count)
        XCTAssertEqual(mesh.indices.count % 3, 0)

        let assigned = mesh.muscleIds.filter { $0 >= 0 }
        XCTAssertFalse(assigned.isEmpty, "baked mesh assigned no muscle ids")
        XCTAssertTrue(assigned.allSatisfy { Int($0) < MuscleGroup.allCases.count })
        XCTAssertTrue(mesh.muscleBlend.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    func testCorruptMeshFailsSafely() {
        XCTAssertThrowsError(try MuscleBodyMesh.parse(Data("CM".utf8))) { error in
            XCTAssertEqual(error as? MuscleBodyMeshError, .truncated)
        }
        var invalidHeader = Data("NOPE".utf8)
        invalidHeader.append(Data(repeating: 0, count: 16))
        XCTAssertThrowsError(try MuscleBodyMesh.parse(invalidHeader)) { error in
            XCTAssertEqual(error as? MuscleBodyMeshError, .invalidHeader)
        }
    }

    // MARK: - Mapping

    func testCommonLiftsResolveToMuscles() {
        for lift in ["Bench Press", "Squat", "Deadlift", "Pull Up", "Bicep Curl"] {
            let activation = ExerciseMuscleMap.activation(for: lift)
            XCTAssertNotNil(activation, "\(lift) should be in the table")
            XCTAssertFalse(activation?.isEmpty ?? true, "\(lift) resolved to nothing")
        }
    }

    func testBenchPressMapsChestAboveTricepsAndFrontDelts() {
        let activation = ExerciseMuscleMap.activation(for: "Bench Press")
        XCTAssertEqual(activation?[.chest], 1)
        XCTAssertEqual(activation?[.triceps], 0.5)
        XCTAssertEqual(activation?[.frontDelts], 0.5)
    }

    func testSquatMapsQuadsAndGlutesWithSecondaryPosterior() {
        let activation = ExerciseMuscleMap.activation(for: "Squat")
        XCTAssertEqual(activation?[.quads], 1)
        XCTAssertEqual(activation?[.glutes], 1)
        XCTAssertEqual(activation?[.hamstrings], 0.5)
        XCTAssertEqual(activation?[.lowerBack], 0.5)
    }

    func testLookupIgnoresCasingAndSpacing() {
        let canonical = ExerciseMuscleMap.activation(for: "Bench Press")
        XCTAssertEqual(ExerciseMuscleMap.activation(for: "bench press"), canonical)
        XCTAssertEqual(ExerciseMuscleMap.activation(for: "  BENCH   PRESS  "), canonical)
    }

    func testUnknownExerciseIsReportedRatherThanGuessed() {
        XCTAssertNil(ExerciseMuscleMap.activation(for: "Zercher Good Morning Jump"))
        let result = ExerciseMuscleMap.workoutIntensities(
            exercises: [("Bench Press", 4), ("Zercher Good Morning Jump", 3)])
        XCTAssertTrue(result.unresolved.contains("Zercher Good Morning Jump"))
        XCTAssertFalse(result.intensities.isEmpty, "the known lift should still count")
    }

    func testIntensitiesAreNormalisedToUnitRange() {
        let result = ExerciseMuscleMap.workoutIntensities(
            exercises: [("Bench Press", 10), ("Squat", 2)])
        for (group, value) in result.intensities {
            XCTAssertGreaterThan(value, 0, "\(group.rawValue) should carry work")
            XCTAssertLessThanOrEqual(value, 1.0, "\(group.rawValue) exceeds 1.0")
        }
        XCTAssertNil(result.intensities[.calves], "unworked muscles stay missing")
    }

    func testMoreVolumeMeansMoreIntensity() {
        let light = ExerciseMuscleMap.workoutIntensities(exercises: [("Bench Press", 1), ("Squat", 10)])
        let heavy = ExerciseMuscleMap.workoutIntensities(exercises: [("Bench Press", 8), ("Squat", 10)])
        let l = light.intensities[.chest] ?? 0
        let h = heavy.intensities[.chest] ?? 0
        XCTAssertGreaterThan(h, l, "more chest volume should shade the chest harder")
    }

    func testVertexColorsBlendAssignedMusclesAndLeaveBaseUntrained() {
        let mesh = MuscleBodyMesh.shared()
        let colors = MuscleBodyMaterial.vertexColors(
            mesh: mesh,
            intensities: [.chest: 1.0],
            selected: [],
            style: .dark
        )
        XCTAssertEqual(colors.count, mesh.vertexCount)
        var sawWorked = false
        var sawBase = false
        for i in 0..<mesh.vertexCount {
            let color = colors[i]
            if mesh.muscleIds[i] == Int16(MuscleGroup.chest.meshIndex), mesh.muscleBlend[i] > 0.8 {
                XCTAssertGreaterThan(color.x, color.y)
                sawWorked = true
            }
            if mesh.muscleIds[i] < 0 {
                XCTAssertEqual(color.x, MuscleBodyStyle.dark.baseColor.x, accuracy: 0.001)
                sawBase = true
            }
        }
        XCTAssertTrue(sawWorked)
        XCTAssertTrue(sawBase)
    }
}
