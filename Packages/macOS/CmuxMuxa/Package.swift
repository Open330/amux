// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxMuxa",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMuxa",
            targets: ["CmuxMuxa"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxMuxa"
        ),
        .testTarget(
            name: "CmuxMuxaTests",
            dependencies: ["CmuxMuxa"]
        ),
    ]
)
