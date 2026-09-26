// swift-tools-version:5.9
// SQLCipher Community Edition 4.19.0 (https://www.zetetic.net/sqlcipher/, BSD-style license, see LICENSE.md): the
// official prebuilt XCFramework that SQLCipher.swift 4.19.0 publishes, fetched and checksum-verified by fetch.sh into
// SQLCipher.xcframework (not committed). A local binary target instead of SQLCipher.swift's remote one, because
// xcodebuild hangs while downloading that remote artifact on GitHub's macOS runners. Bump VERSION and SHA256 in fetch.sh
// together with the GRDB copy.
import PackageDescription

let package = Package(
    name: "SQLCipher",
    products: [
        .library(name: "SQLCipher", targets: ["SQLCipher"]),
    ],
    targets: [
        .binaryTarget(name: "SQLCipher", path: "SQLCipher.xcframework"),
    ]
)
