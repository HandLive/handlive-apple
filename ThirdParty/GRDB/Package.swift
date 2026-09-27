// swift-tools-version:6.1
// GRDB.swift 7.11.1 (https://github.com/groue/GRDB.swift, tag v7.11.1, MIT License — see LICENSE), vendored so it can
// be built against SQLCipher: GRDB's README says "To use SQLCipher with the Swift Package Manager, you must fork GRDB,
// and modify Package.swift", following the "GRDB+SQLCipher" comments of its manifest. The GRDB/ sources and
// Sources/GRDBSQLCipher are copied unchanged (GRDB/Documentation.docc left out); only this manifest differs: the system
// SQLite target is removed and GRDB links SQLCipher (Zetetic, BSD-style Community Edition: the prebuilt XCFramework of
// SQLCipher.swift, as the local package ../SQLCipher that fetch.sh fills) with SQLITE_HAS_CODEC. Update both together:
// copy a newer GRDB release and bump the version here, the SQLCipher version in ../SQLCipher/fetch.sh, and NOTICE.
import PackageDescription

let package = Package(
    name: "GRDB",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [
        .library(name: "GRDB", targets: ["GRDB"]),
    ],
    dependencies: [
        .package(path: "../SQLCipher"),
    ],
    targets: [
        .target(
            name: "GRDBSQLCipher",
            dependencies: [.product(name: "SQLCipher", package: "SQLCipher")]
        ),
        .target(
            name: "GRDB",
            dependencies: [
                .product(name: "SQLCipher", package: "SQLCipher"),
                .target(name: "GRDBSQLCipher"),
            ],
            path: "GRDB",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            cSettings: [.define("SQLITE_HAS_CODEC")],
            swiftSettings: [
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_ENABLE_SNAPSHOT"),
                .define("SQLITE_HAS_CODEC"),
                .define("SQLCipher"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
