import CoreGraphics
import Foundation
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
    static let rampWidth = MuscleGroup.allCases.count + 1
    static let rampHeight = 32

    static func groupColors(
        intensities: [MuscleGroup: Double],
        selected: Set<MuscleGroup>,
        style: MuscleBodyStyle
    ) -> [SIMD4<Float>] {
        MuscleGroup.allCases.map { group in
            style.color(for: intensities[group] ?? 0, selected: selected.contains(group))
        }
    }

    /// CPU reference for tests: per-vertex mix of base color and the group ramp.
    static func vertexColors(
        mesh: BodyMesh,
        intensities: [MuscleGroup: Double],
        selected: Set<MuscleGroup>,
        style: MuscleBodyStyle
    ) -> [SIMD4<Float>] {
        let groupColor = groupColors(intensities: intensities, selected: selected, style: style)
        var colors = [SIMD4<Float>](repeating: style.baseColor, count: mesh.positions.count)
        for v in 0..<mesh.positions.count {
            let id = mesh.muscleIds[v]
            guard id >= 0, Int(id) < groupColor.count else { continue }
            let blend = mesh.muscleBlend[v]
            colors[v] = simd_mix(style.baseColor, groupColor[Int(id)], SIMD4(repeating: blend))
        }
        return colors
    }

    /// Immutable UVs: x selects base vs muscle column, y is the baked blend weight.
    static func textureCoordinates(mesh: BodyMesh) -> [SIMD2<Float>] {
        let width = Float(rampWidth)
        return (0..<mesh.vertexCount).map { index in
            let id = mesh.muscleIds[index]
            if id < 0 {
                return SIMD2(0.5 / width, 0)
            }
            return SIMD2((Float(id) + 1.5) / width, mesh.muscleBlend[index])
        }
    }

    static func makeSurfaceMaterial(texture: TextureResource) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(texture: .init(texture))
        material.roughness = .init(floatLiteral: 0.48)
        material.metallic = .init(floatLiteral: 0.10)
        material.faceCulling = .none
        return material
    }

    static func makeRampTexture(
        intensities: [MuscleGroup: Double],
        selected: Set<MuscleGroup>,
        style: MuscleBodyStyle
    ) throws -> TextureResource {
        let groupColor = groupColors(intensities: intensities, selected: selected, style: style)
        let width = rampWidth
        let height = rampHeight
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let blend = height == 1 ? 1 : Float(y) / Float(height - 1)
            write(style.baseColor, x: 0, y: y, width: width, pixels: &pixels)
            for group in 0..<groupColor.count {
                let mixed = simd_mix(style.baseColor, groupColor[group], SIMD4(repeating: blend))
                write(mixed, x: group + 1, y: y, width: width, pixels: &pixels)
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            throw MuscleBodyMeshError.truncated
        }
        return try TextureResource.generate(
            from: image,
            withName: "muscleMapRamp",
            options: TextureResource.CreateOptions(semantic: .color)
        )
    }

    private static func write(
        _ color: SIMD4<Float>,
        x: Int,
        y: Int,
        width: Int,
        pixels: inout [UInt8]
    ) {
        let i = (y * width + x) * 4
        pixels[i] = channel(color.x)
        pixels[i + 1] = channel(color.y)
        pixels[i + 2] = channel(color.z)
        pixels[i + 3] = channel(color.w)
    }

    private static func channel(_ value: Float) -> UInt8 {
        UInt8(max(0, min(1, value)) * 255)
    }
}
