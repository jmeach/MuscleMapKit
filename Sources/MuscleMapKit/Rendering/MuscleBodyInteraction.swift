import Foundation
import RealityKit
import simd
import SwiftUI

/// Rotation / zoom / idle-spin policy for `MuscleBody3DView`.
///
/// Horizontal drag rotates yaw. Vertical-dominant drags are ignored so a parent
/// `ScrollView` can keep scrolling. Pinch magnifies, and wins over yaw for as
/// long as it is active because a two-finger centroid also moves horizontally.
/// Reduce Motion disables idle spin and inertia but leaves direct manipulation —
/// yaw and zoom — available.
///
/// Zoom is kept here as a plain scalar; `MuscleBody3DView` hands it to
/// `MuscleBodyEntity.applyZoom(_:)`, so this type stays free of camera and
/// entity-tree knowledge.
@MainActor
final class MuscleBodyInteraction {
    private(set) var yaw: Float
    private var dragOriginYaw: Float = 0
    private var lastTranslation: CGSize = .zero
    private var axis: AxisLock = .undecided
    private var idleWorkItem: DispatchWorkItem?
    private var idleController: AnimationPlaybackController?
    private var inertiaController: AnimationPlaybackController?

    /// Camera-distance magnification, `1` = the default bounds-fitted framing.
    /// Persists across gestures: zoom is only reset by pinching back to `1`.
    private(set) var zoomScale: Float = MuscleBodyFraming.minZoom
    private(set) var isMagnifying = false
    private var magnificationOrigin: Float = MuscleBodyFraming.minZoom

    private enum AxisLock {
        case undecided
        case horizontal
        case vertical
    }

    init(initialYaw: Float) {
        yaw = initialYaw
    }

    func applyYaw(to body: Entity) {
        body.orientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
    }

    func beginDrag(body: Entity) {
        stopIdle(body: body)
        inertiaController?.stop()
        inertiaController = nil
        dragOriginYaw = yaw
        lastTranslation = .zero
        axis = .undecided
    }

    /// Returns `true` when this drag is rotating the body.
    func updateDrag(translation: CGSize, body: Entity) -> Bool {
        // A live pinch moves its centroid too. Track the translation so the
        // axis decision restarts from where the fingers actually are, but never
        // yaw while magnifying.
        guard !isMagnifying else {
            lastTranslation = translation
            axis = .undecided
            return false
        }
        if axis == .undecided {
            let dx = abs(translation.width)
            let dy = abs(translation.height)
            if hypot(dx, dy) < 8 {
                lastTranslation = translation
                return false
            }
            axis = dx > dy * 1.15 ? .horizontal : .vertical
            // Rebase on the deciding frame. A drag that only becomes a drag
            // after a pinch (or one that arrives already displaced) would
            // otherwise convert its whole accumulated translation into yaw.
            lastTranslation = translation
            return false
        }
        guard axis == .horizontal else {
            lastTranslation = translation
            return false
        }
        let delta = Float(translation.width - lastTranslation.width)
        lastTranslation = translation
        yaw += delta * 0.011
        applyYaw(to: body)
        return true
    }

    func endDrag(
        predictedTranslation: CGSize,
        velocity: CGSize,
        body: Entity,
        autoRotate: Bool,
        reduceMotion: Bool
    ) {
        defer {
            axis = .undecided
            lastTranslation = .zero
        }
        guard !isMagnifying else {
            scheduleIdle(body: body, autoRotate: autoRotate, reduceMotion: reduceMotion, after: 3)
            return
        }
        guard axis == .horizontal else {
            scheduleIdle(body: body, autoRotate: autoRotate, reduceMotion: reduceMotion, after: 3)
            return
        }

        if !reduceMotion {
            let vx = Float(velocity.width)
            if abs(vx) > 80 {
                let extra = vx * 0.0006
                yaw += extra
                let target = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
                body.move(
                    to: Transform(scale: body.scale, rotation: target, translation: body.position),
                    relativeTo: body.parent,
                    duration: 0.8
                )
            }
        } else {
            applyYaw(to: body)
        }
        scheduleIdle(body: body, autoRotate: autoRotate, reduceMotion: reduceMotion, after: 3)
    }

    func cancelDrag(body: Entity, autoRotate: Bool, reduceMotion: Bool) {
        axis = .undecided
        lastTranslation = .zero
        scheduleIdle(body: body, autoRotate: autoRotate, reduceMotion: reduceMotion, after: 3)
    }

    func isTap(translation: CGSize) -> Bool {
        hypot(translation.width, translation.height) < 10
    }

    // MARK: - Magnification

    /// Pinch start: direct manipulation, so idle spin and inertia stop and any
    /// in-flight drag stops rotating.
    func beginMagnification(body: Entity) {
        stopIdle(body: body)
        inertiaController?.stop()
        inertiaController = nil
        isMagnifying = true
        magnificationOrigin = zoomScale
        axis = .undecided
        lastTranslation = .zero
    }

    /// Applies a `MagnifyGesture` magnification, which is relative to the start
    /// of the current pinch, on top of the zoom the user already had. Returns
    /// the clamped zoom to hand to the camera.
    @discardableResult
    func updateMagnification(_ magnification: CGFloat) -> Float {
        let requested = magnificationOrigin * Float(magnification)
        zoomScale = MuscleBodyFraming.clampZoom(requested)
        return zoomScale
    }

    /// Pinch end: the zoom persists, and idle spin resumes on the same delay as
    /// any other direct manipulation. The camera is never animated back to the
    /// default framing.
    func endMagnification(body: Entity, autoRotate: Bool, reduceMotion: Bool) {
        isMagnifying = false
        magnificationOrigin = zoomScale
        axis = .undecided
        lastTranslation = .zero
        scheduleIdle(body: body, autoRotate: autoRotate, reduceMotion: reduceMotion, after: 3)
    }

    func scheduleIdle(
        body: Entity,
        autoRotate: Bool,
        reduceMotion: Bool,
        after delay: TimeInterval
    ) {
        idleWorkItem?.cancel()
        guard autoRotate, !reduceMotion else { return }
        let work = DispatchWorkItem { [weak self, weak body] in
            guard let self, let body else { return }
            self.startIdle(body: body)
        }
        idleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func stopIdle(body: Entity) {
        idleWorkItem?.cancel()
        idleWorkItem = nil
        idleController?.stop()
        idleController = nil
        body.stopAllAnimations()
        applyYaw(to: body)
    }

    func pauseForBackground(body: Entity) {
        stopIdle(body: body)
    }

    private func startIdle(body: Entity) {
        stopIdle(body: body)
        let animation = FromToByAnimation<Transform>(
            by: Transform(rotation: simd_quatf(angle: 2 * .pi, axis: SIMD3(0, 1, 0))),
            duration: 26,
            timing: .linear,
            isAdditive: true,
            bindTarget: .transform,
            repeatMode: .repeat
        )
        guard let resource = try? AnimationResource.generate(with: animation) else { return }
        idleController = body.playAnimation(resource)
    }
}
