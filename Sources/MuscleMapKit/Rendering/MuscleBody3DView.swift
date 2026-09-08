import RealityKit
import SwiftUI

/// Interactive RealityKit body that shades muscle regions from a `0...1` intensity map.
///
/// The scene shell appears immediately; the baked mesh is attached once and then
/// mutated in place via the color vertex buffer. An explicit perspective camera
/// frames the mesh bounds so the full figure stays visible. Drag horizontally
/// to yaw. Vertical drags are ignored so a parent `ScrollView` can keep
/// scrolling. Pass `interactive: false` only when the map must not handle
/// gestures at all.
public struct MuscleBody3DView: View {
    var intensities: [MuscleGroup: Double]
    var selected: Set<MuscleGroup> = []
    var autoRotate = true
    var interactive = true
    var initialYaw: Float = 0
    var style: MuscleBodyStyle? = nil
    var onTapMuscle: ((MuscleGroup) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    @State private var session = Session()

    /// - Parameters:
    ///   - intensities: per-muscle work `0...1`; muscles left out render untrained.
    ///   - selected: muscles drawn with the boosted highlight tint.
    ///   - autoRotate: slow idle spin, paused while the user is dragging.
    ///   - interactive: master switch for gestures — pass false only when the
    ///     parent must own every touch.
    ///   - initialYaw: resting rotation in radians, e.g. a 3/4 angle.
    ///   - style: optional palette; defaults follow Light/Dark Mode.
    ///   - onTapMuscle: called with the muscle under a tap.
    public init(
        intensities: [MuscleGroup: Double],
        selected: Set<MuscleGroup> = [],
        autoRotate: Bool = true,
        interactive: Bool = true,
        initialYaw: Float = 0,
        style: MuscleBodyStyle? = nil,
        onTapMuscle: ((MuscleGroup) -> Void)? = nil
    ) {
        self.intensities = intensities
        self.selected = selected
        self.autoRotate = autoRotate
        self.interactive = interactive
        self.initialYaw = initialYaw
        self.style = style
        self.onTapMuscle = onTapMuscle
    }

    private var resolvedStyle: MuscleBodyStyle {
        style ?? .default(for: colorScheme == .dark ? .dark : .light)
    }

    public var body: some View {
        RealityView { content in
            content.camera = .virtual
            if content.entities.isEmpty {
                content.add(session.model.root)
            }
            await session.attachIfNeeded(
                intensities: intensities,
                selected: selected,
                style: resolvedStyle,
                initialYaw: initialYaw
            )
            session.interaction.scheduleIdle(
                body: session.model.body,
                autoRotate: autoRotate && !reduceMotion,
                reduceMotion: reduceMotion,
                after: 1.2
            )
        } update: { _ in
            session.model.apply(
                intensities: intensities,
                selected: selected,
                style: resolvedStyle
            )
        }
        .realityViewCameraControls(.none)
        .modifier(FlexibleRealityLayout())
        .contentShape(Rectangle())
        .simultaneousGesture(dragGesture, including: interactive ? .all : .none)
        .simultaneousGesture(tapGesture, including: interactive ? .all : .none)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                session.interaction.pauseForBackground(body: session.model.body)
            } else if autoRotate && !reduceMotion {
                session.interaction.scheduleIdle(
                    body: session.model.body,
                    autoRotate: true,
                    reduceMotion: false,
                    after: 1.2
                )
            }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced {
                session.interaction.pauseForBackground(body: session.model.body)
            }
        }
        .accessibilityHidden(true)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if session.dragBegan == false {
                    session.interaction.beginDrag(body: session.model.body)
                    session.dragBegan = true
                }
                _ = session.interaction.updateDrag(translation: value.translation, body: session.model.body)
            }
            .onEnded { value in
                session.dragBegan = false
                session.interaction.endDrag(
                    predictedTranslation: value.predictedEndTranslation,
                    velocity: CGSize(
                        width: value.predictedEndTranslation.width - value.translation.width,
                        height: value.predictedEndTranslation.height - value.translation.height
                    ),
                    body: session.model.body,
                    autoRotate: autoRotate,
                    reduceMotion: reduceMotion
                )
            }
    }

    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .targetedToAnyEntity()
            .onEnded { value in
                session.interaction.stopIdle(body: session.model.body)
                let muscle = muscleFromHit(value)
                guard let muscle else { return }
                session.model.pulseSelection()
                onTapMuscle?(muscle)
                session.interaction.scheduleIdle(
                    body: session.model.body,
                    autoRotate: autoRotate,
                    reduceMotion: reduceMotion,
                    after: 3
                )
            }
    }

    private func muscleFromHit(_ value: EntityTargetValue<SpatialTapGesture.Value>) -> MuscleGroup? {
        let hits = value.hitTest(point: value.location, in: .local, query: .nearest, mask: .all)
        if let face = hits.first?.triangleHit?.faceIndex,
           let muscle = session.model.muscle(atFace: face) {
            return muscle
        }
        if let position = hits.first?.position {
            let local = session.model.body.convert(position: position, from: nil)
            return session.model.muscle(nearestToLocal: local)
        }
        return nil
    }

    @MainActor
    final class Session {
        let model = MuscleBodyEntity()
        lazy var interaction = MuscleBodyInteraction(initialYaw: 0)
        var dragBegan = false
        private var didAttach = false

        func attachIfNeeded(
            intensities: [MuscleGroup: Double],
            selected: Set<MuscleGroup>,
            style: MuscleBodyStyle,
            initialYaw: Float
        ) async {
            if !didAttach {
                interaction = MuscleBodyInteraction(initialYaw: initialYaw)
                didAttach = true
            }
            do {
                try model.attachCachedMesh(
                    intensities: intensities,
                    selected: selected,
                    style: style
                )
                model.body.components.set(OpacityComponent(opacity: 0))
                interaction.applyYaw(to: model.body)
                if #available(iOS 26.0, *) {
                    Entity.animate(.easeOut(duration: 0.9), body: { [model] in
                        model.body.components.set(OpacityComponent(opacity: 1))
                    })
                } else {
                    model.body.components.set(OpacityComponent(opacity: 1))
                }
            } catch {
                model.body.components.set(OpacityComponent(opacity: 1))
            }
        }
    }
}

private struct FlexibleRealityLayout: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.realityViewLayoutBehavior(.flexible)
        } else {
            content
        }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        MuscleBody3DView(
            intensities: [.chest: 1.0, .triceps: 0.6, .frontDelts: 0.5, .abs: 0.25]
        )
    }
}
