// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MuscleMapKit",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(name: "MuscleMapKit", targets: ["MuscleMapKit"]),
    ],
    targets: [
        .target(
            name: "MuscleMapKit",
            path: "Sources/MuscleMapKit",
            resources: [.copy("Resources/body.mesh")]
        ),
        .testTarget(
            name: "MuscleMapKitTests",
            dependencies: ["MuscleMapKit"],
            path: "Tests/MuscleMapKitTests"
        ),
    ]
)
