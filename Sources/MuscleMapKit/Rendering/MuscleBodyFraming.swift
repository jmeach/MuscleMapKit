import simd

/// Deterministic camera framing derived from the baked body's mesh bounds.
///
/// The mesh origin sits at the feet (`y ≈ 0`). RealityKit's default virtual
/// camera orbits an entity origin, so targeting `body` itself crops the head.
/// Framing is computed from the axis-aligned bounds: look at the visual
/// center, fit height (plus a small margin) into a vertical field of view,
/// and back the camera up far enough that an arbitrary yaw around world Y
/// still keeps the bounding-box corners on screen.
struct MuscleBodyFraming: Equatable, Sendable {
    var lookAt: SIMD3<Float>
    var cameraPosition: SIMD3<Float>
    var fieldOfViewDegrees: Float
    var near: Float
    var far: Float
    var distance: Float
    var aspect: Float

    static let defaultFieldOfViewDegrees: Float = 36
    /// Fractional extra height applied equally above the head and below the feet.
    /// `0.06` leaves a small safety band without shrinking the figure.
    static let defaultVerticalMargin: Float = 0.06
    /// Conservative width/height used when the SwiftUI viewport is unknown.
    /// Overview/detail cards on iPhone are wider than this; a lower aspect
    /// only increases distance if horizontal fit would otherwise clip.
    static let defaultAspect: Float = 0.70
    static let defaultNear: Float = 0.1
    static let defaultFar: Float = 20

    /// Zoom is a camera-distance multiplier, not an entity scale. `1` is the
    /// bounds-fitted full-body framing and doubles as the minimum: the map never
    /// pulls back farther than the shot it was designed around.
    static let minZoom: Float = 1
    /// Enough magnification to inspect a small group (forearms, calves) without
    /// the near plane or the mesh interior coming into view.
    static let maxZoom: Float = 2.75

    var fieldOfViewRadians: Float {
        fieldOfViewDegrees * .pi / 180
    }

    /// Camera pose that keeps `bounds` fully visible, including after yaw.
    static func fit(
        bounds: MeshBounds,
        fieldOfViewDegrees: Float = defaultFieldOfViewDegrees,
        verticalMargin: Float = defaultVerticalMargin,
        aspect: Float = defaultAspect,
        near: Float = defaultNear,
        far: Float = defaultFar
    ) -> MuscleBodyFraming {
        let lookAt = bounds.center
        let fov = max(fieldOfViewDegrees, 1)
        let margin = max(verticalMargin, 0)
        let aspectRatio = max(aspect, 0.05)
        let pad = (bounds.extent.y * 0.5) * margin
        let expanded = MeshBounds(min: bounds.min - SIMD3(repeating: pad), max: bounds.max + SIMD3(repeating: pad))
        let vHalfAngle = (fov * .pi / 180) * 0.5
        let hHalfAngle = atan(tan(vHalfAngle) * aspectRatio)
        let tanV = max(tan(vHalfAngle), 1e-5)
        let tanH = max(tan(hHalfAngle), 1e-5)

        // Perspective scale depends on depth: corners closer to the camera
        // (larger world z) occupy more of the frustum than the bounds center.
        // Fit the expanded AABB and its yaw about world Y so a full spin stays on screen.
        var distance: Float = 0
        for yaw in [Float(0), .pi / 2, .pi, 3 * .pi / 2] {
            for corner in expanded.corners {
                let point = Self.yawed(corner, angle: yaw)
                let towardCamera = point.z - lookAt.z
                let vertical = abs(point.y - lookAt.y) / tanV + towardCamera
                let horizontal = abs(point.x - lookAt.x) / tanH + towardCamera
                distance = max(distance, vertical, horizontal)
            }
        }
        distance = max(distance, 0.1)
        let cameraPosition = SIMD3(lookAt.x, lookAt.y, lookAt.z + distance)
        return MuscleBodyFraming(
            lookAt: lookAt,
            cameraPosition: cameraPosition,
            fieldOfViewDegrees: fov,
            near: near,
            far: far,
            distance: distance,
            aspect: aspectRatio
        )
    }

    /// True when `point` projects inside the perspective frustum, with a tiny
    /// epsilon so exact-edge corners still count as contained.
    func contains(_ point: SIMD3<Float>, epsilon: Float = 1e-4) -> Bool {
        let ndc = projectedNDC(point)
        return abs(ndc.x) <= 1 + epsilon && abs(ndc.y) <= 1 + epsilon
    }

    /// Perspective project a world point into NDC xy. The camera looks along
    /// world −Z from `cameraPosition` toward `lookAt`.
    func projectedNDC(_ point: SIMD3<Float>) -> SIMD2<Float> {
        let vHalf = fieldOfViewRadians * 0.5
        let hHalf = atan(tan(vHalf) * aspect)
        let x = point.x - cameraPosition.x
        let y = point.y - cameraPosition.y
        let zForward = cameraPosition.z - point.z
        let denom = max(zForward, 1e-5)
        return SIMD2(x / (tan(hHalf) * denom), y / (tan(vHalf) * denom))
    }

    func containsBounds(_ bounds: MeshBounds, epsilon: Float = 1e-4) -> Bool {
        bounds.corners.allSatisfy { contains($0, epsilon: epsilon) }
    }

    func containsBounds(_ bounds: MeshBounds, yaw: Float, epsilon: Float = 1e-4) -> Bool {
        bounds.corners.allSatisfy { contains(Self.yawed($0, angle: yaw), epsilon: epsilon) }
    }

    // MARK: - Zoom

    /// Clamps to the supported magnification range. Non-finite input (a gesture
    /// producing NaN) falls back to the default framing rather than losing the camera.
    static func clampZoom(_ zoom: Float) -> Float {
        guard zoom.isFinite else { return minZoom }
        return Swift.min(Swift.max(zoom, minZoom), maxZoom)
    }

    /// Camera distance from `lookAt` at `zoom`. The viewing direction, field of
    /// view, and near/far planes are unchanged; only the distance shortens.
    func distance(zoom: Float) -> Float {
        distance / Self.clampZoom(zoom)
    }

    /// Camera position at `zoom`, moved along the original view ray toward `lookAt`.
    func cameraPosition(zoom: Float) -> SIMD3<Float> {
        let direction = cameraPosition - lookAt
        return lookAt + direction / Self.clampZoom(zoom)
    }

    private static func yawed(_ point: SIMD3<Float>, angle: Float) -> SIMD3<Float> {
        let c = cos(angle)
        let s = sin(angle)
        return SIMD3(point.x * c + point.z * s, point.y, -point.x * s + point.z * c)
    }
}
