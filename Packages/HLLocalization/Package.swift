// swift-tools-version: 6.0
import PackageDescription

// Tests use swift-testing: with Xcode the `Testing` module ships with it; with Command Line Tools only,
// set HL_SWIFT_TESTING_PACKAGE=1 to fetch the swift-testing package.
let useSwiftTestingPackage = Context.environment["HL_SWIFT_TESTING_PACKAGE"] == "1"

// Xcode compiles the String Catalog (xcstringstool). Command Line Tools cannot, so that mode (the one that sets
// HL_SWIFT_TESTING_PACKAGE=1) ships the same strings as .lproj files the generator writes beside it.
let hasXcode = !useSwiftTestingPackage
let stringCatalog = "Resources/Localizable.xcstrings"
let commandLineToolsStrings = "CommandLineToolsResources"

let package = Package(
    name: "HLLocalization",
    defaultLocalization: "en",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "HLLocalization", targets: ["HLLocalization"]),
    ],
    dependencies: useSwiftTestingPackage
        ? [.package(url: "https://github.com/swiftlang/swift-testing.git", branch: "release/6.2")]
        : [],
    targets: [
        .target(
            name: "HLLocalization",
            exclude: hasXcode ? [commandLineToolsStrings] : [stringCatalog],
            resources: hasXcode ? [.process(stringCatalog)] : [.process(commandLineToolsStrings)]
        ),
        .testTarget(
            name: "HLLocalizationTests",
            dependencies: ["HLLocalization"]
                + (useSwiftTestingPackage ? [.product(name: "Testing", package: "swift-testing")] : [])
        ),
    ]
)
