// swift-tools-version: 6.0
import PackageDescription

// Tests use swift-testing: with Xcode the `Testing` module ships with it; with Command Line Tools only,
// set HL_SWIFT_TESTING_PACKAGE=1 to fetch the swift-testing package.
let useSwiftTestingPackage = Context.environment["HL_SWIFT_TESTING_PACKAGE"] == "1"

// SMS on Mac and iPhone/iPad (05-sms.md): the SQLCipher database of 0.9.3 through GRDB (vendored in ThirdParty/GRDB,
// built against SQLCipher) and the SMS engine. Only the apps link it; the Notification Service Extension does not.
let package = Package(
    name: "HLSMS",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "HLSMS", targets: ["HLSMS"]),
        // Notification content and categories only, without the database: the Notification Service Extension links this.
        .library(name: "HLSMSNotifications", targets: ["HLSMSNotifications"]),
    ],
    dependencies: [
        .package(path: "../HLProtocol"), .package(path: "../HLCrypto"), .package(path: "../HLTransport"),
        .package(path: "../HLLocalization"), .package(path: "../../ThirdParty/GRDB"),
    ] + (useSwiftTestingPackage
        ? [.package(url: "https://github.com/swiftlang/swift-testing.git", branch: "release/6.2")]
        : []),
    targets: [
        .target(name: "HLSMS", dependencies: ["HLProtocol", "HLTransport", .product(name: "GRDB", package: "GRDB")]),
        .target(name: "HLSMSNotifications", dependencies: ["HLProtocol", "HLCrypto", "HLTransport", "HLLocalization"]),
        .testTarget(
            name: "HLSMSTests",
            dependencies: ["HLSMS", "HLProtocol", "HLTransport", .product(name: "GRDB", package: "GRDB")]
                + (useSwiftTestingPackage ? [.product(name: "Testing", package: "swift-testing")] : [])
        ),
        .testTarget(
            name: "HLSMSNotificationsTests",
            dependencies: ["HLSMSNotifications", "HLProtocol", "HLCrypto", "HLLocalization"]
                + (useSwiftTestingPackage ? [.product(name: "Testing", package: "swift-testing")] : [])
        ),
    ]
)
