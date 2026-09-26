// swift-tools-version: 6.0
import PackageDescription

// Tests use swift-testing: with Xcode the `Testing` module ships with it; with Command Line Tools only,
// set HL_SWIFT_TESTING_PACKAGE=1 to fetch the swift-testing package. SwiftUI views here build with the macOS 26 SDK;
// with Command Line Tools on a newer SDK, point SDKROOT at MacOSX26.sdk (see README).
let useSwiftTestingPackage = Context.environment["HL_SWIFT_TESTING_PACKAGE"] == "1"

// The Messages screens shared by the Mac window and the iPhone/iPad tab (SMS-01…05): models over the encrypted
// database (GRDB observation) and the SwiftUI views built from ThreadRow and MessageBubble.
let package = Package(
    name: "HLSMSUI",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "HLSMSUI", targets: ["HLSMSUI"]),
    ],
    dependencies: [
        .package(path: "../HLProtocol"), .package(path: "../HLSMS"), .package(path: "../HLDesignSystem"),
        .package(path: "../HLLocalization"), .package(path: "../../ThirdParty/GRDB"),
    ] + (useSwiftTestingPackage
        ? [.package(url: "https://github.com/swiftlang/swift-testing.git", branch: "release/6.2")]
        : []),
    targets: [
        .target(
            name: "HLSMSUI",
            dependencies: [
                "HLProtocol", "HLDesignSystem", "HLLocalization",
                .product(name: "HLSMS", package: "HLSMS"), .product(name: "HLSMSNotifications", package: "HLSMS"),
                .product(name: "GRDB", package: "GRDB"),
            ],
            swiftSettings: useSwiftTestingPackage ? [.define("HL_COMMAND_LINE_TOOLS_ONLY")] : []
        ),
        .testTarget(
            name: "HLSMSUITests",
            dependencies: ["HLSMSUI", "HLProtocol", .product(name: "HLSMS", package: "HLSMS")]
                + (useSwiftTestingPackage ? [.product(name: "Testing", package: "swift-testing")] : [])
        ),
    ]
)
