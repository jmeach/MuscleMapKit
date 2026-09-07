import Foundation
import RealityKit
import simd
import SwiftUI

/// Rotation / idle-spin policy for `MuscleBody3DView`.
///
/// Horizontal drag rotates yaw. Vertical-dominant drags are ignored so a parent
/// `ScrollView` can keep scrolling. Reduce Motion disables idle spin and inertia
/// but leaves direct yaw changes available.
@MainActor
final class MuscleBodyInteraction {
    private(set) var yaw: Float
    private var dragOriginYaw: Float = 0
    private var lastTranslation: CGSize = .zero
    private var axis: AxisLock = .undecided
    private var idleWorkItem: DispatchWorkItem?
    private var idleController: AnimationPlaybackController?
    private var inertiaController: AnimationPlaybackController?

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
        if axis == .undecided {
            let dx = abs(translation.width)
            let dy = abs(translation.height)
            if hypot(dx, dy) < 8 {
                lastTranslation = translation
                return false
            }
            axis = dx > dy * 1.15 ? .horizontal : .vertical
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
