import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
import Testing
@testable import HLDesignSystem

/// Đọc tokens.json độc lập với script sinh (lần bí danh `{token}`), rồi so với Color Set và mã Swift.
private struct TokenColors {
    static let themes = ["light", "dark", "light-hc", "dark-hc"]
    let raw: [String: Any]
    let names: [String]

    init() throws {
        let color = try RepositoryPaths.json(at: RepositoryPaths.tokensJSON)["color"] as? [String: Any] ?? [:]
        let tokens = color["tokens"] as? [[String: Any]] ?? []
        names = tokens.compactMap { $0["name"] as? String }
        raw = Dictionary(uniqueKeysWithValues: tokens.compactMap { item in
            (item["name"] as? String).map { ($0, item["value"] as Any) }
        })
    }

    /// Hex của token ở một giao diện, đã lần theo bí danh.
    func hex(_ name: String, theme: String) -> String {
        let value = raw[name]
        if let text = value as? String {
            return text.hasPrefix("{") ? hex(String(text.dropFirst().dropLast()), theme: theme) : text
        }
        return (value as? [String: String])?[theme] ?? ""
    }
}

/// Chuyển "#rrggbb[aa]" thành (r, g, b, a) 0…255.
private func bytes(_ hex: String) -> [Int] {
    let digits = Array(hex.dropFirst())
    let padded = digits.count == 6 ? digits + ["f", "f"] : digits
    return stride(from: 0, to: 8, by: 2).map { Int(String(padded[$0...$0 + 1]), radix: 16) ?? -1 }
}

/// Đọc một Color Set: khóa giao diện ("light", "dark", "light-hc", "dark-hc") → (r, g, b, a).
private func colorSet(named name: String) throws -> [String: [Int]] {
    let url = RepositoryPaths.colorCatalog.appendingPathComponent("\(name).colorset/Contents.json")
    let colors = try RepositoryPaths.json(at: url)["colors"] as? [[String: Any]] ?? []
    var result: [String: [Int]] = [:]
    for entry in colors {
        let appearances = (entry["appearances"] as? [[String: String]] ?? []).compactMap { $0["value"] }
        let key = switch (appearances.contains("dark"), appearances.contains("high")) {
        case (false, false): "light"
        case (true, false): "dark"
        case (false, true): "light-hc"
        case (true, true): "dark-hc"
        }
        let components = (entry["color"] as? [String: Any])?["components"] as? [String: String] ?? [:]
        let channels = ["red", "green", "blue"].map { Int(components[$0]?.dropFirst(2) ?? "", radix: 16) ?? -1 }
        let alpha = Int(((Double(components["alpha"] ?? "") ?? -1) * 255).rounded())
        result[key] = channels + [alpha]
    }
    return result
}

@Suite("Color Sets 4 giao diện")
struct ColorSetTests {
    @Test("Mỗi màu trong tokens.json có Color Set đủ 4 giao diện, đúng giá trị")
    func everyTokenHasFourAppearances() throws {
        let tokens = try TokenColors()
        #expect(!tokens.names.isEmpty)
        for name in tokens.names {
            let set = try colorSet(named: name)
            #expect(set.count == 4, "\(name): \(set.keys.sorted())")
            for theme in TokenColors.themes {
                let expected = bytes(tokens.hex(name, theme: theme))
                let actual = set[theme] ?? []
                // Alpha trong Color Set là số thập phân 3 chữ số → sai số tối đa 1/255.
                #expect(Array(actual.prefix(3)) == Array(expected.prefix(3)), "\(name) \(theme)")
                #expect(abs((actual.last ?? -9) - expected[3]) <= 1, "\(name) \(theme) alpha")
            }
        }
    }

    @Test("AccentColor = accent-fill, cả trong package và catalog của app")
    func accentColorMatchesAccentFillToken() throws {
        #expect(try colorSet(named: "AccentColor") == colorSet(named: "accent-fill"))
        let appAccent = RepositoryPaths.appAssetCatalog.appendingPathComponent("AccentColor.colorset/Contents.json")
        let packageAccent = RepositoryPaths.colorCatalog.appendingPathComponent("AccentColor.colorset/Contents.json")
        #expect(try Data(contentsOf: appAccent) == Data(contentsOf: packageAccent))
    }

    @Test("Mã Swift sinh ra có cùng giá trị với tokens.json")
    func generatedPaletteMatchesTokens() throws {
        let tokens = try TokenColors()
        #expect(HLColorToken.allCases.map(\.rawValue) == tokens.names)
        for token in HLColorToken.allCases {
            let palette = token.palette
            let values = [palette.light, palette.dark, palette.lightHighContrast, palette.darkHighContrast]
            for (theme, value) in zip(TokenColors.themes, values) {
                let actual = [value.red, value.green, value.blue, value.alpha].map(Int.init)
                #expect(actual == bytes(tokens.hex(token.rawValue, theme: theme)), "\(token) \(theme)")
            }
        }
    }

    @Test("Màu hệ thống gọi API, không dùng hex", arguments: [
        (HLColorToken.statusConnected, Color.green), (.statusConnecting, .orange), (.statusOffline, .gray),
        (.statusError, .red), (.badge, .red), (.secondaryLabel, .secondary), (.label, .primary),
        (.link, .accentColor),
    ])
    func systemColorsUseSystemAPI(token: HLColorToken, expected: Color) {
        #expect(token.systemColor == expected)
        #expect(token.resolved(colorScheme: .dark, contrast: .increased) == expected)
    }

    #if os(macOS)
    /// Bảng "Màu ngữ nghĩa và API" của 01-mau-sac.md, cột AppKit: màu có API thì gọi API, hex chỉ khi thiếu API.
    @Test("Màu ngữ nghĩa trên Mac gọi NSColor", arguments: [
        (HLColorToken.tertiaryLabel, NSColor.tertiaryLabelColor), (.quaternaryLabel, .quaternaryLabelColor),
        (.placeholderText, .placeholderTextColor), (.separator, .separatorColor),
        (.windowBackground, .windowBackgroundColor), (.controlBackground, .controlBackgroundColor),
    ])
    func semanticColorsUseAppKit(token: HLColorToken, expected: NSColor) {
        #expect(token.systemColor == Color(nsColor: expected))
    }

    @Test("Nền tô systemFill… chỉ có API từ macOS 14; macOS 13 dùng hex của token")
    func fillColorsNeedMacOS14() {
        let fills: [HLColorToken] = [.systemFill, .secondarySystemFill, .tertiarySystemFill, .quaternarySystemFill]
        for token in fills {
            if #available(macOS 14, *) {
                #expect(token.systemColor != nil, "\(token)")
            } else {
                #expect(token.systemColor == nil, "\(token)")
            }
        }
    }

    @Test("Token không có API AppKit giữ hex: nền iOS, Gray 2–6, màu thương hiệu")
    func tokensWithoutAppKitAPIUseTokenValues() {
        let hexOnly: [HLColorToken] = [
            .systemBackground, .systemGroupedBackground, .opaqueSeparator, .systemGray2, .systemGray6,
            .accent, .accentFill, .brandFire, .textRed, .destructiveText, .unread,
        ]
        for token in hexOnly {
            #expect(token.systemColor == nil, "\(token)")
        }
    }
    #endif

    @Test("Màu tự định nghĩa chọn đúng giao diện")
    func customColorResolvesPerAppearance() {
        let palette = HLColorToken.accent.palette
        #expect(palette.value(colorScheme: .light, contrast: .standard) == HLRGBA(0x19, 0x79, 0x34, 0xFF))
        #expect(palette.value(colorScheme: .dark, contrast: .standard) == palette.dark)
        #expect(palette.value(colorScheme: .light, contrast: .increased) == palette.lightHighContrast)
        #expect(palette.value(colorScheme: .dark, contrast: .increased) == palette.darkHighContrast)
        #expect(HLColorToken.accent.systemColor == nil)
    }
}
