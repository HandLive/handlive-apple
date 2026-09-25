import Foundation

/// Paths in the workspace, derived from this file (independent of the working directory).
enum WorkspaceFiles {
    /// apple/Packages/HLLocalization/Tests/HLLocalizationTests/<file> → workspace root (six levels up).
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }()

    static let appleRoot = root.appendingPathComponent("apple")
    static let packageRoot = appleRoot.appendingPathComponent("Packages/HLLocalization")
    static let catalog = root.appendingPathComponent("shared/strings/ui-strings.json")
    static let generator = packageRoot.appendingPathComponent("Scripts/generate-strings.py")
    static let localizableCatalog = packageRoot
        .appendingPathComponent("Sources/HLLocalization/Resources/Localizable.xcstrings")
    static let accessors = packageRoot.appendingPathComponent("Sources/HLLocalization/Generated/L10n.swift")
    static let appInfoPlistCatalog = appleRoot.appendingPathComponent("macOS/HandLive/Resources/InfoPlist.xcstrings")
    static let appInfoPlist = appleRoot.appendingPathComponent("macOS/Info.plist")

    /// Python of the shared repo's tools venv when present, else the system python3 (the script needs only the
    /// standard library).
    static var python: URL {
        let venv = root.appendingPathComponent("shared/tools/.venv/bin/python")
        return FileManager.default.isExecutableFile(atPath: venv.path) ? venv : URL(fileURLWithPath: "/usr/bin/python3")
    }

    static func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }
}

/// One entry of shared/strings/ui-strings.json, read independently of the generator.
struct CatalogEntry {
    let key: String
    let texts: [String: Any]
    let platforms: [String]
    let args: [(name: String, type: String)]
    let plistKey: String?

    var isApple: Bool { platforms.contains("macos") || platforms.contains("ios") }
    var isPlural: Bool { texts["en"] is [String: String] }

    static func all() throws -> [CatalogEntry] {
        let strings = try WorkspaceFiles.json(WorkspaceFiles.catalog)["strings"] as? [[String: Any]] ?? []
        return strings.map { item in
            CatalogEntry(
                key: item["key"] as? String ?? "",
                texts: ["en": item["en"] as Any, "vi": item["vi"] as Any],
                platforms: item["platforms"] as? [String] ?? [],
                args: (item["args"] as? [[String: String]] ?? []).map { ($0["name"] ?? "", $0["type"] ?? "") },
                plistKey: item["plist_key"] as? String
            )
        }
    }

    /// Catalog text with every {name} replaced by the given values.
    func expected(_ language: String, category: String? = nil, values: [String: String]) -> String {
        var text: String
        if let category, let plural = texts[language] as? [String: String] {
            text = plural[category] ?? plural["other"] ?? ""
        } else {
            text = texts[language] as? String ?? ""
        }
        for (name, value) in values { text = text.replacingOccurrences(of: "{\(name)}", with: value) }
        return text
    }
}
