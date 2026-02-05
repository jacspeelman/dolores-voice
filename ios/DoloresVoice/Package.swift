// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DoloresVoice",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "DoloresVoice",
            targets: ["DoloresVoice"]
        ),
    ],
    dependencies: [
        // Dependencies will be added here as needed
    ],
    targets: [
        .target(
            name: "DoloresVoice",
            dependencies: [],
            path: "Sources/DoloresVoice"
        ),
        .testTarget(
            name: "DoloresVoiceTests",
            dependencies: ["DoloresVoice"],
            path: "Tests/DoloresVoiceTests"
        ),
    ]
)
