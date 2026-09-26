import Foundation

/// Looks catalog strings up in this package's resource bundle. The system picks the language: the first of the
/// user's preferred languages (or the app's own language in System Settings › General › Language & Region ›
/// Applications) that the bundle has, English otherwise (0.12.3).
public enum L10nLookup {
    /// String table compiled from `Localizable.xcstrings` (or the `.lproj` fallback without Xcode).
    public static let table = "Localizable"

    /// Resource bundle holding the compiled catalog.
    public static var bundle: Bundle { .module }

    /// Text of a string without arguments, in the language the system chose.
    public static func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: table)
    }

    /// Text with arguments (`%1$@`, `%1$lld`, plural variants) in the language the system chose.
    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        format(key, arguments: arguments, bundle: bundle, localization: bundle.preferredLocalizations.first)
    }

    /// Text in one given language, whatever the user prefers (tests, previews in both languages).
    public static func string(_ key: String, localization: String) -> String {
        languageBundle(localization)?.localizedString(forKey: key, value: nil, table: table) ?? key
    }

    /// Formatted text in one given language.
    public static func format(_ key: String, localization: String, _ arguments: CVarArg...) -> String {
        format(key, localization: localization, arguments: arguments)
    }

    /// Formatted text in one given language, arguments as an array.
    public static func format(_ key: String, localization: String, arguments: [CVarArg]) -> String {
        guard let bundle = languageBundle(localization) else { return key }
        return format(key, arguments: arguments, bundle: bundle, localization: localization)
    }

    private static func format(_ key: String, arguments: [CVarArg], bundle: Bundle, localization: String?) -> String {
        let format = bundle.localizedString(forKey: key, value: nil, table: table)
        // Plural rules follow the language of the text, not the region settings (a Vietnamese text under an
        // English region still has only the "other" form).
        let locale = Locale(identifier: localization ?? "en")
        return String(format: format, locale: locale, arguments: arguments)
    }

    private static func languageBundle(_ localization: String) -> Bundle? {
        bundle.path(forResource: localization, ofType: "lproj").flatMap(Bundle.init(path:))
    }
}
