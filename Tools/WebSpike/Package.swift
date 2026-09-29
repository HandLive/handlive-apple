// swift-tools-version: 6.0
import PackageDescription

// Web spike (gate G6): a development-only probe for Continue Browsing on the Mac. While a supported browser is
// frontmost it asks that browser, through Apple Events, for the front window's active tab and its private mode, and
// logs the host and a salted hash only. It is not part of the apps and builds with the Command Line Tools:
// `swift build`. The Info.plist is embedded in the binary; `Support/make-app.sh` wraps the binary in an app bundle to
// test the Automation (TCC) prompt of a signed app. WebSpikeCore holds the logic the tests cover.
let package = Package(
    name: "WebSpike",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "WebSpikeCore"),
        .executableTarget(
            name: "WebSpike",
            dependencies: ["WebSpikeCore"],
            linkerSettings: [
                .linkedFramework("AppKit"), .linkedFramework("ApplicationServices"),
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", Context.packageDirectory + "/Support/Info.plist"]),
            ]
        ),
        .testTarget(name: "WebSpikeCoreTests", dependencies: ["WebSpikeCore"]),
    ]
)
