// swift-tools-version: 6.0
import PackageDescription

// Tests use swift-testing: with Xcode the `Testing` module ships with it; with Command Line Tools only,
// set HL_SWIFT_TESTING_PACKAGE=1 to fetch the swift-testing package. SwiftUI views here build with the macOS 26
// SDK; with Command Line Tools on a newer SDK, point SDKROOT at MacOSX26.sdk (see README).
let useSwiftTestingPackage = Context.environment["HL_SWIFT_TESTING_PACKAGE"] == "1"

let package = Package(
    name: "HLMacUI",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HLMacUI", targets: ["HLMacUI"]),
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
            name: "HLMacUI",
            dependencies: ["HLProtocol", "HLCrypto", "HLTransport", "HLAppCore", "HLDesignSystem", "HLLocalization",
                           .product(name: "HLSMS", package: "HLSMS"),
                           .product(name: "HLSMSNotifications", package: "HLSMS"), "HLSMSUI",
                           .product(name: "HLCalls", package: "HLCalls"),
                           .product(name: "HLCallNotifications", package: "HLCalls"),
                           .product(name: "HLCallsUI", package: "HLCalls")],
            swiftSettings: useSwiftTestingPackage ? [.define("HL_COMMAND_LINE_TOOLS_ONLY")] : []
        ),
        .testTarget(
            name: "HLMacUITests",
            dependencies: ["HLMacUI", "HLAppCore", "HLTransport", "HLProtocol", "HLDesignSystem", "HLLocalization",
                           .product(name: "HLSMS", package: "HLSMS"),
                           .product(name: "HLSMSNotifications", package: "HLSMS"), "HLSMSUI",
                           .product(name: "HLCalls", package: "HLCalls"),
                           .product(name: "HLCallNotifications", package: "HLCalls"),
                           .product(name: "HLCallsUI", package: "HLCalls")]
                + (useSwiftTestingPackage ? [.product(name: "Testing", package: "swift-testing")] : [])
        ),
    ]
)
