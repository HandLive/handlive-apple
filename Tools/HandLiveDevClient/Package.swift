// swift-tools-version: 6.0
import PackageDescription

// HandLive Dev Client: a headless, development-only Mac client built from the real Apple packages, to test them
// against the real Android app in an emulator (pairing with a PIN, the /v1/ctl session, calls, SMS, clipboard). It is
// not part of the apps, not in the Xcode project, and builds with the Command Line Tools alone: `swift build`.
let package = Package(
    name: "HandLiveDevClient",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/HLProtocol"), .package(path: "../../Packages/HLCrypto"),
        .package(path: "../../Packages/HLTransport"), .package(path: "../../Packages/HLAppCore"),
        .package(path: "../../Packages/HLSMS"), .package(path: "../../Packages/HLCalls"),
    ],
    targets: [
        .executableTarget(
            name: "HandLiveDevClient",
            dependencies: ["HLProtocol", "HLCrypto", "HLTransport", "HLAppCore",
                           .product(name: "HLSMS", package: "HLSMS"), .product(name: "HLCalls", package: "HLCalls")]
        ),
    ]
)
