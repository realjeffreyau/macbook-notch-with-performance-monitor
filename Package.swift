// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DynamicNotch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DynamicNotch", targets: ["DynamicNotch"]),
        .executable(name: "DynamicNotchMediaDiagnostic", targets: ["DynamicNotchMediaDiagnostic"])
    ],
    targets: [
        .target(
            name: "MediaRemoteBridge",
            path: "Sources/MediaRemoteBridge",
            publicHeadersPath: "include",
            cSettings: [
                // MediaRemote completion handlers are Objective-C blocks. The
                // bridge owns that ABI so Swift never guesses a block cast.
                .unsafeFlags(["-fblocks"])
            ]
        ),
        .target(
            name: "DynamicNotchMedia",
            dependencies: ["MediaRemoteBridge"],
            path: "Sources/DynamicNotchMedia"
        ),
        .executableTarget(
            name: "DynamicNotch",
            dependencies: ["DynamicNotchMedia"],
            path: "Sources/DynamicNotch"
        ),
        .executableTarget(
            name: "DynamicNotchMediaDiagnostic",
            dependencies: ["DynamicNotchMedia"],
            path: "Sources/DynamicNotchMediaDiagnostic"
        ),
        .testTarget(
            name: "DynamicNotchTests",
            dependencies: ["DynamicNotch", "DynamicNotchMedia"],
            path: "Tests/DynamicNotchTests"
        ),
        .testTarget(
            name: "DynamicNotchMediaDiagnosticTests",
            dependencies: ["DynamicNotchMediaDiagnostic", "DynamicNotchMedia"],
            path: "Tests/DynamicNotchMediaDiagnosticTests"
        )
    ]
)
