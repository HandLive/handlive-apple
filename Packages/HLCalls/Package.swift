// swift-tools-version: 6.0
import PackageDescription

// Tests use swift-testing: with Xcode the `Testing` module ships with it; with Command Line Tools only,
// set HL_SWIFT_TESTING_PACKAGE=1 to fetch the swift-testing package. The SwiftUI views of HLCallsUI build with the
// macOS 26 SDK; with Command Line Tools on a newer SDK, point SDKROOT at MacOSX26.sdk (see README).
let useSwiftTestingPackage = Context.environment["HL_SWIFT_TESTING_PACKAGE"] == "1"
let testing: [Target.Dependency] = useSwiftTestingPackage ? [.product(name: "Testing", package: "swift-testing")] : []

// Calls on the Mac and the iPhone/iPad (06-call-control.md): the call log in the encrypted database with its sync
// (HLCalls), the call notifications and the push decoding the Notification Service Extension shares (HLCallNotifications,
// no database), and the call list both apps show (HLCallsUI).
let package = Package(
    name: "HLCalls",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "HLCalls", targets: ["HLCalls"]),
        .library(name: "HLCallNotifications", targets: ["HLCallNotifications"]),
        .library(name: "HLCallsUI", targets: ["HLCallsUI"]),
    ],
    dependencies: [
        .package(path: "../HLProtocol"), .package(path: "../HLCrypto"), .package(path: "../HLTransport"),
        .package(path: "../HLAppCore"), .package(path: "../HLLocalization"), .package(path: "../HLDesignSystem"),
        .package(path: "../HLSMS"), .package(path: "../../ThirdParty/GRDB"),
    ] + (useSwiftTestingPackage
        ? [.package(url: "https://github.com/swiftlang/swift-testing.git", branch: "release/6.2")]
        : []),
    targets: [
        .target(
            name: "HLCallNotifications",
            dependencies: ["HLProtocol", "HLCrypto", "HLTransport", "HLAppCore", "HLLocalization",
                           .product(name: "HLSMSNotifications", package: "HLSMS")]
        ),
        .target(
            name: "HLCalls",
            dependencies: ["HLProtocol", "HLTransport", "HLAppCore", .product(name: "HLSMS", package: "HLSMS"),
                           .product(name: "GRDB", package: "GRDB")]
        ),
        .target(
            name: "HLCallsUI",
            dependencies: ["HLCalls", "HLCallNotifications", "HLAppCore", "HLDesignSystem", "HLLocalization",
                           "HLProtocol", .product(name: "GRDB", package: "GRDB")],
            swiftSettings: useSwiftTestingPackage ? [.define("HL_COMMAND_LINE_TOOLS_ONLY")] : []
        ),
        .testTarget(
            name: "HLCallsTests",
            dependencies: ["HLCalls", "HLCallsUI", "HLAppCore", "HLProtocol", "HLTransport", "HLLocalization",
                           .product(name: "HLSMS", package: "HLSMS"), .product(name: "GRDB", package: "GRDB")]
                + testing
        ),
        .testTarget(
            name: "HLCallNotificationsTests",
            dependencies: ["HLCallNotifications", "HLAppCore", "HLProtocol", "HLCrypto", "HLLocalization"] + testing
        ),
    ]
)
