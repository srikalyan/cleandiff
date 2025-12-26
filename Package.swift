// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CleanDiff",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "cleandiff", targets: ["CleanDiff"]),
        .library(name: "CleanDiffCore", targets: ["CleanDiffCore"])
    ],
    dependencies: [],
    targets: [
        // Core library (testable)
        .target(
            name: "CleanDiffCore",
            dependencies: [],
            path: "Sources/CleanDiffCore"
        ),
        // Executable
        .executableTarget(
            name: "CleanDiff",
            dependencies: ["CleanDiffCore"],
            path: "Sources/CleanDiff"
        ),
        // Tests
        .testTarget(
            name: "CleanDiffTests",
            dependencies: ["CleanDiffCore"],
            path: "Tests/CleanDiffTests"
        )
    ]
)
