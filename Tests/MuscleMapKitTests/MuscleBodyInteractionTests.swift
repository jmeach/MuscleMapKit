import RealityKit
import XCTest
@testable import MuscleMapKit

/// Gesture policy: yaw, pinch zoom, and the arbitration between them.
/// These exercise `MuscleBodyInteraction` directly — the scalar zoom it owns is
/// what `MuscleBody3DView` hands to the camera.
@MainActor
final class MuscleBodyInteractionTests: XCTestCase {

    private func makeInteraction(initialYaw: Float = 0) -> (MuscleBodyInteraction, Entity) {
        (MuscleBodyInteraction(initialYaw: initialYaw), Entity())
    }

    /// Drives a drag past the axis-decision threshold. The deciding frame only
    /// rebases the translation, so rotation starts on the frame after it.
    private func drag(
        _ interaction: MuscleBodyInteraction,
        body: Entity,
        to translation: CGSize
    ) {
        interaction.beginDrag(body: body)
        _ = interaction.updateDrag(translation: CGSize(width: 2, height: 0), body: body)
        _ = interaction.updateDrag(
            translation: CGSize(width: translation.width * 0.6, height: translation.height * 0.6),
            body: body
        )
        _ = interaction.updateDrag(translation: translation, body: body)
    }

    // MARK: - Yaw

    func testHorizontalDragChangesYaw() {
        let (interaction, body) = makeInteraction()
        let start = interaction.yaw
        drag(interaction, body: body, to: CGSize(width: 120, height: 4))
        XCTAssertGreaterThan(interaction.yaw, start)
    }

    func testVerticalDominantDragLeavesYawAloneForTheParentScrollView() {
        let (interaction, body) = makeInteraction(initialYaw: 0.35)
        drag(interaction, body: body, to: CGSize(width: 10, height: 140))
        XCTAssertEqual(interaction.yaw, 0.35, accuracy: 1e-6)
    }

    func testDecidingFrameDoesNotConvertAccumulatedTranslationIntoYaw() {
        let (interaction, body) = makeInteraction()
        interaction.beginDrag(body: body)
        // First frame already far from the origin, e.g. a finger left over from a pinch.
        _ = interaction.updateDrag(translation: CGSize(width: 300, height: 0), body: body)
        XCTAssertEqual(interaction.yaw, 0, accuracy: 1e-6)
        _ = interaction.updateDrag(translation: CGSize(width: 310, height: 0), body: body)
        XCTAssertEqual(interaction.yaw, 10 * 0.011, accuracy: 1e-5)
    }

    // MARK: - Magnification

    func testMagnificationStartsAtTheDefaultFraming() {
        let (interaction, _) = makeInteraction()
        XCTAssertEqual(interaction.zoomScale, MuscleBodyFraming.minZoom, accuracy: 1e-6)
        XCTAssertFalse(interaction.isMagnifying)
    }

    func testBeginMagnificationMarksDirectManipulation() {
        let (interaction, body) = makeInteraction()
        interaction.beginMagnification(body: body)
        XCTAssertTrue(interaction.isMagnifying)
    }

    func testMagnificationUpdatesZoom() {
        let (interaction, body) = makeInteraction()
        interaction.beginMagnification(body: body)
        XCTAssertEqual(interaction.updateMagnification(1.8), 1.8, accuracy: 1e-5)
        XCTAssertEqual(interaction.zoomScale, 1.8, accuracy: 1e-5)
    }

    func testMagnificationClampsToTheSupportedRange() {
        let (interaction, body) = makeInteraction()
        interaction.beginMagnification(body: body)
        XCTAssertEqual(interaction.updateMagnification(12), MuscleBodyFraming.maxZoom, accuracy: 1e-5)
        XCTAssertEqual(interaction.updateMagnification(0.01), MuscleBodyFraming.minZoom, accuracy: 1e-5)
    }

    func testZoomIsRetainedAfterTheGestureEnds() {
        let (interaction, body) = makeInteraction()
        interaction.beginMagnification(body: body)
        _ = interaction.updateMagnification(2.0)
        interaction.endMagnification(body: body, autoRotate: true, reduceMotion: false)
        XCTAssertFalse(interaction.isMagnifying)
        XCTAssertEqual(interaction.zoomScale, 2.0, accuracy: 1e-5, "zoom must not reset on release")
    }

    func testRepeatedGestureOriginsCompose() {
        let (interaction, body) = makeInteraction()
        interaction.beginMagnification(body: body)
        _ = interaction.updateMagnification(2.0)
        interaction.endMagnification(body: body, autoRotate: true, reduceMotion: false)

        interaction.beginMagnification(body: body)
        // MagnifyGesture magnification is relative to the start of each pinch.
        XCTAssertEqual(interaction.updateMagnification(1.2), 2.4, accuracy: 1e-5)
        interaction.endMagnification(body: body, autoRotate: true, reduceMotion: false)
        XCTAssertEqual(interaction.zoomScale, 2.4, accuracy: 1e-5)
    }

    func testPinchingBackInReturnsTowardTheDefaultFraming() {
        let (interaction, body) = makeInteraction()
        interaction.beginMagnification(body: body)
        _ = interaction.updateMagnification(2.4)
        interaction.endMagnification(body: body, autoRotate: true, reduceMotion: false)

        interaction.beginMagnification(body: body)
        _ = interaction.updateMagnification(0.2)
        interaction.endMagnification(body: body, autoRotate: true, reduceMotion: false)
        XCTAssertEqual(interaction.zoomScale, MuscleBodyFraming.minZoom, accuracy: 1e-5)
    }

    func testReduceMotionStillPermitsDirectMagnification() {
        let (interaction, body) = makeInteraction()
        interaction.beginMagnification(body: body)
        _ = interaction.updateMagnification(1.7)
        interaction.endMagnification(body: body, autoRotate: false, reduceMotion: true)
        XCTAssertEqual(interaction.zoomScale, 1.7, accuracy: 1e-5)
    }

    // MARK: - Arbitration

    func testActiveMagnificationPreventsYawMutation() {
        let (interaction, body) = makeInteraction()
        drag(interaction, body: body, to: CGSize(width: 100, height: 0))
        let yawBeforePinch = interaction.yaw

        interaction.beginMagnification(body: body)
        _ = interaction.updateDrag(translation: CGSize(width: 400, height: 0), body: body)
        _ = interaction.updateDrag(translation: CGSize(width: 800, height: 0), body: body)
        XCTAssertEqual(interaction.yaw, yawBeforePinch, accuracy: 1e-6)
    }

    func testDragResumesRotatingAfterTheMagnificationEnds() {
        let (interaction, body) = makeInteraction()
        interaction.beginDrag(body: body)
        interaction.beginMagnification(body: body)
        _ = interaction.updateDrag(translation: CGSize(width: 400, height: 0), body: body)
        let yawDuringPinch = interaction.yaw
        interaction.endMagnification(body: body, autoRotate: false, reduceMotion: true)

        _ = interaction.updateDrag(translation: CGSize(width: 420, height: 0), body: body)
        _ = interaction.updateDrag(translation: CGSize(width: 440, height: 0), body: body)
        XCTAssertGreaterThan(interaction.yaw, yawDuringPinch)
        XCTAssertLessThan(interaction.yaw - yawDuringPinch, 0.5, "must not replay the pinch translation")
    }

    func testEndingADragDuringMagnificationDoesNotFlingTheBody() {
        let (interaction, body) = makeInteraction()
        drag(interaction, body: body, to: CGSize(width: 120, height: 0))
        interaction.beginMagnification(body: body)
        let yaw = interaction.yaw
        interaction.endDrag(
            predictedTranslation: CGSize(width: 900, height: 0),
            velocity: CGSize(width: 780, height: 0),
            body: body,
            autoRotate: false,
            reduceMotion: false
        )
        XCTAssertEqual(interaction.yaw, yaw, accuracy: 1e-6)
    }
}
