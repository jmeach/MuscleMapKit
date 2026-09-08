import Foundation
import Metal
import RealityKit
import simd
import UIKit

/// Palette for the continuous body. Intensity is a visualization scale, not a
/// physiological percentage: `1.0` is the hardest-worked muscle in the current
/// snapshot.
public struct MuscleBodyStyle: Sendable, Equatable {
    public var baseColor: SIMD4<Float>
    public var idleRegionColor: SIMD4<Float>
    public var selectedMix: Float
    public var selectedColor: SIMD4<Float>
    public var workedLow: SIMD4<Float>
    public var workedHigh: SIMD4<Float>

    public init(
        baseColor: SIMD4<Float>,
        idleRegionColor: SIMD4<Float>,
        selectedMix: Float = 0.30,
        selectedColor: SIMD4<Float>,
        workedLow: SIMD4<Float>,
        workedHigh: SIMD4<Float>
    ) {
        self.baseColor = baseColor
        self.idleRegionColor = idleRegionColor
        self.selectedMix = selectedMix
        self.selectedColor = selectedColor
        self.workedLow = workedLow
        self.workedHigh = workedHigh
    }

    /// Graphite body with a rose → deep-red work ramp (original package look).
    public static let dark = MuscleBodyStyle(
        baseColor: SIMD4(0.110, 0.110, 0.125, 1),
        idleRegionColor: SIMD4(0.185, 0.185, 0.205, 1),
        selectedColor: SIMD4(1.0, 0.15, 0.12, 1),
        workedLow: SIMD4(0.86, 0.52, 0.54, 1),
        workedHigh: SIMD4(0.72, 0.08, 0.10, 1)
    )

    /// Lighter body so inactive anatomy stays readable on light surfaces.
    public static let light = MuscleBodyStyle(
        baseColor: SIMD4(0.82, 0.82, 0.84, 1),
        idleRegionColor: SIMD4(0.70, 0.70, 0.73, 1),
        selectedColor: SIMD4(0.92, 0.18, 0.16, 1),
        workedLow: SIMD4(0.93, 0.48, 0.42, 1),
        workedHigh: SIMD4(0.78, 0.10, 0.12, 1)
    )

    public static func `default`(for colorScheme: UIUserInterfaceStyle) -> MuscleBodyStyle {
        colorScheme == .light ? .light : .dark
    }

    public func color(for intensity: Double, selected: Bool) -> SIMD4<Float> {
        let t = Float(MuscleIntensity.clamp(intensity))
        var color = t > 0.001 ? ramp(t) : idleRegionColor
        if selected {
            color = simd_mix(color, selectedColor, SIMD4(repeating: selectedMix))
        }
        return color
    }

    private func ramp(_ t: Float) -> SIMD4<Float> {
        simd_mix(workedLow, workedHigh, SIMD4(repeating: t))
    }
}

enum MuscleBodyMaterialError: Error, Equatable {
    case noMetalDevice
    case missingMetalLibrary
    case missingSurfaceShader(String)
}

enum MuscleBodyMaterial {
    static let surfaceShaderName = "muscleMapSurface"
    static let roughness: Float = 0.48
    static let metallic: Float = 0.10

    static func groupColors(
        intensities: [MuscleGroup: Double],
        selected: Set<MuscleGroup>,
        style: MuscleBodyStyle
    ) -> [SIMD4<Float>] {
        MuscleGroup.allCases.map { group in
            style.color(for: intensities[group] ?? 0, selected: selected.contains(group))
        }
    }

    /// `MuscleGroup.allCases`-ordered selection flags, matching `groupColors`
    /// and the per-vertex `muscleIds` encoding.
    static func groupSelection(_ selected: Set<MuscleGroup>) -> [Bool] {
        MuscleGroup.allCases.map { selected.contains($0) }
    }

    /// Per-vertex mix of the graphite base and the group intensity color.
    static func vertexColors(
        mesh: BodyMesh,
        intensities: [MuscleGroup: Double],
        selected: Set<MuscleGroup>,
        style: MuscleBodyStyle
    ) -> [SIMD4<Float>] {
        var colors = [SIMD4<Float>](repeating: style.baseColor, count: mesh.positions.count)
        colors.withUnsafeMutableBufferPointer { buffer in
            writeVertexColors(
                to: buffer,
                mesh: mesh,
                intensities: intensities,
                selected: selected,
                style: style
            )
        }
        return colors
    }

    /// Writes `rgb` = the rendered anatomy/work color and `w` = the selected-muscle
    /// mask consumed by `muscleMapSurface`.
    ///
    /// The fourth component is a private data channel, not opacity: the material is
    /// opaque and the shader only ever reads `w` as the selection mask. Selected
    /// vertices carry `muscleBlend` so the halo follows the same soft anatomical
    /// edges as the color regions; everything else carries `0`.
    static func writeVertexColors(
        to buffer: UnsafeMutableBufferPointer<SIMD4<Float>>,
        mesh: BodyMesh,
        intensities: [MuscleGroup: Double],
        selected: Set<MuscleGroup>,
        style: MuscleBodyStyle
    ) {
        let groupColor = groupColors(intensities: intensities, selected: selected, style: style)
        let groupIsSelected = groupSelection(selected)
        let count = min(buffer.count, mesh.positions.count)
        for v in 0..<count {
            let id = mesh.muscleIds[v]
            guard id >= 0, Int(id) < groupColor.count else {
                var base = style.baseColor
                base.w = 0
                buffer[v] = base
                continue
            }
            let blend = mesh.muscleBlend[v]
            var color = simd_mix(style.baseColor, groupColor[Int(id)], SIMD4(repeating: blend))
            color.w = groupIsSelected[Int(id)] ? blend : 0
            buffer[v] = color
        }
    }

    static func loadMetalLibrary(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws -> MTLLibrary {
        guard let device else {
            throw MuscleBodyMaterialError.noMetalDevice
        }
        do {
            return try device.makeDefaultLibrary(bundle: .module)
        } catch {
            throw MuscleBodyMaterialError.missingMetalLibrary
        }
    }

    @MainActor
    static func makeSurfaceMaterial() throws -> CustomMaterial {
        if let cached = cachedMaterial {
            return cached
        }
        let library = try loadMetalLibrary()
        let shader = CustomMaterial.SurfaceShader(named: surfaceShaderName, in: library)
        let material: CustomMaterial
        do {
            // `.lit` CustomMaterial pipelines bind more texture slots than the
            // iOS Simulator GPU allows (index 31 > 30). Unlit still runs the
            // Metal surface shader; lighting and red glow are computed there.
            var created = try CustomMaterial(surfaceShader: shader, lightingModel: .unlit)
            created.roughness = .init(floatLiteral: roughness)
            created.metallic = .init(floatLiteral: metallic)
            created.faceCulling = .none
            material = created
        } catch {
            throw MuscleBodyMaterialError.missingSurfaceShader(surfaceShaderName)
        }
        cachedMaterial = material
        return material
    }

    @MainActor
    private static var cachedMaterial: CustomMaterial?
}
