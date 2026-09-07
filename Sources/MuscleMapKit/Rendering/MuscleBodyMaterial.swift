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

enum MuscleBodyMaterial {
    static func vertexColors(
        mesh: BodyMesh,
        intensities: [MuscleGroup: Double],
        selected: Set<MuscleGroup>,
        style: MuscleBodyStyle
    ) -> [SIMD4<Float>] {
        let all = MuscleGroup.allCases
        var groupColor = [SIMD4<Float>](repeating: style.idleRegionColor, count: all.count)
        for (i, group) in all.enumerated() {
            groupColor[i] = style.color(for: intensities[group] ?? 0, selected: selected.contains(group))
        }

        var colors = [SIMD4<Float>](repeating: style.baseColor, count: mesh.positions.count)
        for v in 0..<mesh.positions.count {
            let id = mesh.muscleIds[v]
            guard id >= 0, Int(id) < groupColor.count else { continue }
            let blend = mesh.muscleBlend[v]
            colors[v] = simd_mix(style.baseColor, groupColor[Int(id)], SIMD4(repeating: blend))
        }
        return colors
    }

    static func makeSurfaceMaterial() throws -> any Material {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return fallbackMaterial()
        }
        let library: MTLLibrary
        if let moduleLibrary = try? device.makeDefaultLibrary(bundle: .module) {
            library = moduleLibrary
        } else if let defaultLibrary = device.makeDefaultLibrary() {
            library = defaultLibrary
        } else {
            return fallbackMaterial()
        }

        do {
            let shader = CustomMaterial.SurfaceShader(named: "muscleMapSurface", in: library)
            var material = try CustomMaterial(surfaceShader: shader, lightingModel: .lit)
            material.faceCulling = .none
            material.roughness = CustomMaterial.Roughness(floatLiteral: 0.48)
            material.metallic = CustomMaterial.Metallic(floatLiteral: 0.10)
            return material
        } catch {
            return fallbackMaterial()
        }
    }

    private static func fallbackMaterial() -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor.white)
        material.roughness = .init(floatLiteral: 0.48)
        material.metallic = .init(floatLiteral: 0.10)
        material.faceCulling = .none
        return material
    }
}
