# MuscleMapKit

An interactive 3D muscle map for iOS. Hand it a set of muscles and how hard
each was worked, and it renders a body that shades those muscles, spins under
your finger, and reports taps back by muscle group.

<p align="center">
  <img src="Media/demo.gif" width="320" alt="Toggling muscle groups on a rotating 3D body">
</p>

This is the [jmeach/MuscleMapKit](https://github.com/jmeach/MuscleMapKit) fork
used by [coachlyAI](https://github.com/jmeach/coachlyAI). Rendering is
**RealityKit** (SceneKit is not used). The public SwiftUI surface is still
`MuscleBody3DView`.

## Install

```swift
.package(url: "https://github.com/jmeach/MuscleMapKit.git", branch: "main")
```

```swift
.target(name: "YourApp", dependencies: ["MuscleMapKit"])
```

Requires iOS 18+.

## Use it

```swift
import MuscleMapKit

MuscleBody3DView(
    intensities: [.chest: 1.0, .frontDelts: 0.6, .triceps: 0.45]
)
.frame(height: 380)
```

`intensities` is `[MuscleGroup: Double]` in `0…1`. Anything you leave out
renders untrained, so you only pass what was worked.

### Reacting to taps

```swift
MuscleBody3DView(
    intensities: intensities,
    onTapMuscle: { muscle in
        print("tapped \(muscle.displayName)")
    }
)
```

### Inside a scrolling list

Horizontal drags rotate the body. Vertical-dominant drags are ignored so a
parent `ScrollView` can keep scrolling. Pass `interactive: false` only when the
map must not handle gestures at all:

```swift
MuscleBody3DView(
    intensities: intensities,
    autoRotate: false,
    interactive: false,
    initialYaw: .pi / 5
)
```

Reduce Motion disables idle spin and inertial flick while leaving direct
rotation available.

## Turning exercises into muscles

`ExerciseMuscleMap` maps exercise names to the muscles they work, so you can
go straight from a logged workout to a shaded body:

```swift
let result = ExerciseMuscleMap.workoutIntensities(
    exercises: [("Bench Press", 4), ("Squat", 5), ("Barbell Row", 3)]
)

MuscleBody3DView(intensities: result.intensities)
```

Volume drives the shading: more sets on a muscle means a stronger tint.
Names are matched loosely, so `"bench press"`, `"Bench Press"` and
`"  BENCH   PRESS "` all resolve to the same thing.

### Exercises it doesn't know

The table is deliberately finite, and it tells you what it couldn't place
rather than guessing:

```swift
let result = ExerciseMuscleMap.workoutIntensities(
    exercises: [("Bench Press", 4), ("Zercher Good Morning", 3)]
)

result.unresolved   // ["Zercher Good Morning"]
```

Resolve those however you like — a prompt, your own table, a model — and pass
them back in:

```swift
ExerciseMuscleMap.workoutIntensities(
    exercises: exercises,
    resolved: ["Zercher Good Morning": [.hamstrings: 1.0, .lowerBack: 0.7]]
)
```

## Muscle groups

Seventeen, in gym vocabulary rather than medical nomenclature, because that's
how lifters log:

`chest` · `frontDelts` · `sideDelts` · `rearDelts` · `biceps` · `triceps`
`forearms` · `traps` · `lats` · `upperBack` · `lowerBack` · `abs` · `obliques`
`glutes` · `quads` · `hamstrings` · `calves`

Every case has a `displayName` fit for a label.

`MuscleGroup.allCases` order **is** the mesh's id order. Reordering the enum
silently repaints the body onto the wrong muscles. Tests pin that contract.

## How the body is made

It's one continuous mesh, not seventeen separate props.

The [MakeHuman](http://www.makehumancommunity.org/) base mesh (CC0) is morphed
toward an athletic build, normalized to a fixed height and orientation, and
then every vertex is classified into one of the seventeen groups using
limb-axis frames. That gets baked to a compact binary blob — position, normal,
muscle id, and a blend weight per vertex — which ships in the package.

At runtime RealityKit tints by muscle id. Recoloring rewrites a vertex-color
buffer and nothing else, so switching muscles costs no geometry work.

Two consequences worth knowing:

- The order of `MuscleGroup.allCases` **is** the mesh's id order.
- Blend weights soften the seams, so neighbouring groups fade into each other
  instead of ending at a hard edge.

`Tools/bake_body.py` is the baker, kept in the repo so the mesh is
reproducible rather than a mystery binary.

## License

MIT for the code. The bundled mesh derives from MakeHuman's CC0 base mesh; see
[LICENSE](LICENSE).
