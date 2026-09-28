// swift-tools-version: 6.0
import PackageDescription

// Camera spike (gate G5): the pure logic shared by the probe's host app and its Camera Extension — the 720p30 test
// pattern with a millisecond clock and a machine-readable timestamp strip, frame timing, latency statistics and the
// audio click schedule. The apps themselves are in `project.yml` (XcodeGen) because a system extension and a HAL
// plug-in need Xcode; this package builds and tests with `swift test` alone. Not part of the HandLive apps.
let package = Package(
    name: "CameraSpike",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CameraSpikeKit", targets: ["CameraSpikeKit"]),
    ],
    targets: [
        .target(name: "CameraSpikeKit"),
        .testTarget(name: "CameraSpikeKitTests", dependencies: ["CameraSpikeKit"]),
    ]
)
