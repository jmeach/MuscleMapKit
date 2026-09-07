import Foundation

/// Visualization-scale helpers for `[MuscleGroup: Double]` intensity maps.
///
/// Values are a relative shading scale for the current snapshot, not a
/// physiological activation percentage. `1.0` means "highest contribution
/// within this map," not "100% of the muscle's capacity."
public enum MuscleIntensity: Sendable {
    /// Clamps a visualization intensity to `0...1`. Non-finite values become `0`.
    public static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    /// Returns a copy with every intensity clamped to `0...1`.
    public static func clamped(_ intensities: [MuscleGroup: Double]) -> [MuscleGroup: Double] {
        Dictionary(uniqueKeysWithValues: intensities.map { ($0.key, clamp($0.value)) })
    }
}
