// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlowClone",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FlowCloneCore", targets: ["FlowCloneCore"]),
        .executable(name: "FlowClone", targets: ["FlowClone"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4")
    ],
    targets: [
        .target(
            name: "FlowCloneCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/FlowClone",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "FlowClone",
            dependencies: ["FlowCloneCore"],
            path: "Sources/FlowCloneApp",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FlowCloneCoreTests",
            dependencies: ["FlowCloneCore"],
            path: "Tests/FlowCloneCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
