// swift-tools-version: 6.0
import PackageDescription

// Tests use swift-testing: with Xcode the `Testing` module ships with it; with Command Line Tools only,
// set HL_SWIFT_TESTING_PACKAGE=1 to fetch the swift-testing package.
let useSwiftTestingPackage = Context.environment["HL_SWIFT_TESTING_PACKAGE"] == "1"

let package = Package(
    name: "HLAppCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "HLAppCore", targets: ["HLAppCore"]),
    ],
    dependencies: [
        .package(path: "../HLProtocol"), .package(path: "../HLCrypto"), .package(path: "../HLTransport"),
    ] + (useSwiftTestingPackage
        ? [.package(url: "https://github.com/swiftlang/swift-testing.git", branch: "release/6.2")]
        : []),
    targets: [
        .target(name: "HLAppCore", dependencies: ["HLProtocol", "HLCrypto", "HLTransport"]),
        .testTarget(
            name: "HLAppCoreTests",
            dependencies: ["HLAppCore", "HLProtocol", "HLCrypto", "HLTransport"]
                + (useSwiftTestingPackage ? [.product(name: "Testing", package: "swift-testing")] : [])
        ),
    ]
)
