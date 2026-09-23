// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GoProSpatialMaker",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "GoProSpatialMaker",
            path: "Sources/GoProSpatialMaker",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GoProSpatialMakerTests",
            dependencies: ["GoProSpatialMaker"],
            path: "Tests/GoProSpatialMakerTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
