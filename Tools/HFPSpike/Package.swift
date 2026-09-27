// swift-tools-version: 6.0
import PackageDescription

// HFP spike: a development-only probe that answers whether macOS, in the Bluetooth hands-free role, can carry the audio
// of a cellular call from a paired phone, and how macOS exposes that audio to apps. It is not part of the apps and
// builds with the Command Line Tools alone: `swift build`. The Info.plist is embedded in the binary so that macOS can
// ask for Bluetooth and microphone access.
let package = Package(
    name: "HFPSpike",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "HFPSpike",
            linkerSettings: [
                .linkedFramework("IOBluetooth"), .linkedFramework("CoreAudio"), .linkedFramework("AVFoundation"),
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", Context.packageDirectory + "/Info.plist"]),
            ]
        ),
    ],
    // IOBluetooth calls its delegates on the main run loop without concurrency annotations.
    swiftLanguageModes: [.v5]
)
