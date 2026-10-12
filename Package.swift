// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SnapSmith",
    platforms: [.macOS(.v11)],
    targets: [
        .target(name: "CaptureKit"),
        .executableTarget(name: "SnapSmith", dependencies: ["CaptureKit"]),
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit"]),
    ]
)
