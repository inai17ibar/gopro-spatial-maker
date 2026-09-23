// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GoProSpatialMaker",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "GoProSpatialMaker",
            path: "Sources/GoProSpatialMaker"
        ),
        .testTarget(
            name: "GoProSpatialMakerTests",
            dependencies: ["GoProSpatialMaker"],
            path: "Tests/GoProSpatialMakerTests"
        )
    ]
)
