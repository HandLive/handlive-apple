import Foundation
import Testing
@testable import HLLocalization

/// Every Apple string resolves in English and Vietnamese to the catalog text, arguments and plurals included.
/// With Xcode this reads the compiled String Catalog; with Command Line Tools, the generated .lproj fallback.
@Suite("Catalog strings in en and vi")
struct CatalogLookupTests {
    static let languages = ["en", "vi"]

    private func sampleValues(for entry: CatalogEntry) -> (values: [String: String], arguments: [CVarArg]) {
        var values: [String: String] = [:]
        var arguments: [CVarArg] = []
        for (index, arg) in entry.args.enumerated() {
            switch arg.type {
            case "int":
                values[arg.name] = String(7 + index)
                arguments.append(7 + index)
            default:
                let text = "Pixel 8 của Lan \(index)"
                values[arg.name] = text
                arguments.append(text)
            }
        }
        return (values, arguments)
    }

    @Test("Strings without arguments", arguments: languages)
    func plainStrings(language: String) throws {
        let entries = try CatalogEntry.all().filter { $0.isApple && $0.args.isEmpty }
        #expect(!entries.isEmpty)
        for entry in entries {
            #expect(L10nLookup.string(entry.key, localization: language) == entry.expected(language, values: [:]),
                    "\(entry.key) [\(language)]")
        }
    }

    @Test("Strings with arguments keep them in place", arguments: languages)
    func formattedStrings(language: String) throws {
        let entries = try CatalogEntry.all().filter { $0.isApple && !$0.args.isEmpty && !$0.isPlural }
        #expect(!entries.isEmpty)
        for entry in entries {
            let (values, arguments) = sampleValues(for: entry)
            let text = L10nLookup.format(entry.key, localization: language, arguments: arguments)
            #expect(text == entry.expected(language, values: values), "\(entry.key) [\(language)]")
        }
    }

    @Test("Plurals: English one and other, Vietnamese other only")
    func plurals() throws {
        let entries = try CatalogEntry.all().filter { $0.isApple && $0.isPlural }
        #expect(!entries.isEmpty)
        for entry in entries {
            for count in [0, 1, 2, 21] {
                let values = ["count": String(count)]
                let english = L10nLookup.format(entry.key, localization: "en", arguments: [count])
                #expect(english == entry.expected("en", category: count == 1 ? "one" : "other", values: values),
                        "\(entry.key) en \(count)")
                let vietnamese = L10nLookup.format(entry.key, localization: "vi", arguments: [count])
                #expect(vietnamese == entry.expected("vi", category: "other", values: values), "\(entry.key) vi \(count)")
            }
        }
    }

    @Test("A percent sign in a formatted string stays a percent sign")
    func percentSign() {
        let text = L10nLookup.format("clipboard.image_sending", localization: "en", arguments: ["Pixel", "45 %"])
        #expect(text.hasSuffix("45 %"))
    }

    @Test("Accessors resolve in the process language, never to the bare key")
    func accessorsResolve() {
        #expect(L10n.Status.connecting != "status.connecting")
        #expect(L10n.Common.continue != "common.continue")
        #expect(!L10n.Pairing.pairedWith(deviceName: "Pixel").contains("pairing."))
        #expect(!L10n.Status.messagesWaiting(count: 2).contains("status."))
    }
}
