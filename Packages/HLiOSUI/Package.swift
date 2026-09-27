// swift-tools-version: 6.0
import PackageDescription

// Tests use swift-testing: with Xcode the `Testing` module ships with it; with Command Line Tools only,
// set HL_SWIFT_TESTING_PACKAGE=1 to fetch the swift-testing package. The views build only for iOS (CI); the app model
// also builds for macOS so its tests run with the Command Line Tools (point SDKROOT at MacOSX26.sdk, see README).
let useSwiftTestingPackage = Context.environment["HL_SWIFT_TESTING_PACKAGE"] == "1"

// The iPhone and iPad app (SET-03, PAIR-01, CLIP-04, SMS-01…05, CALL-01, CALL-02, CALL-04, SET-02): its model over the
// shared packages and the SwiftUI screens of the Clipboard, Messages, Calls and Settings tabs.
let package = Package(
    name: "HLiOSUI",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "HLiOSUI", targets: ["HLiOSUI"]),
    ],
    dependencies: [
        .package(path: "../HLProtocol"), .package(path: "../HLCrypto"), .package(path: "../HLTransport"),
        .package(path: "../HLAppCore"), .package(path: "../HLDesignSystem"), .package(path: "../HLLocalization"),
        .package(path: "../HLSMS"), .package(path: "../HLSMSUI"), .package(path: "../HLCalls"),
    ] + (useSwiftTestingPackage
        ? [.package(url: "https://github.com/swiftlang/swift-testing.git", branch: "release/6.2")]
        : []),
    targets: [
        .target(
            name: "HLiOSUI",
            dependencies: ["HLProtocol", "HLCrypto", "HLTransport", "HLAppCore", "HLDesignSystem", "HLLocalization",
                           .product(name: "HLSMS", package: "HLSMS"),
                           .product(name: "HLSMSNotifications", package: "HLSMS"), "HLSMSUI",
                           .product(name: "HLCalls", package: "HLCalls"),
                           .product(name: "HLCallNotifications", package: "HLCalls"),
                           .product(name: "HLCallsUI", package: "HLCalls")],
            swiftSettings: useSwiftTestingPackage ? [.define("HL_COMMAND_LINE_TOOLS_ONLY")] : []
        ),
        .testTarget(
            name: "HLiOSUITests",
            dependencies: ["HLiOSUI", "HLAppCore", "HLCrypto", "HLTransport", "HLProtocol", "HLLocalization",
                           .product(name: "HLSMS", package: "HLSMS"),
                           .product(name: "HLSMSNotifications", package: "HLSMS"), "HLSMSUI",
                           .product(name: "HLCalls", package: "HLCalls"),
                           .product(name: "HLCallNotifications", package: "HLCalls")]
                + (useSwiftTestingPackage ? [.product(name: "Testing", package: "swift-testing")] : [])
        ),
    ]
)
