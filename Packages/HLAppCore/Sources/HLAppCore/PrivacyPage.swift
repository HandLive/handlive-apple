import Foundation

/// SET-03 field 1: the privacy page behind "HandLive and Your Privacy" (Onboarding README), in the app's display
/// language; the same pages as the Android app.
public enum PrivacyPage {
    public static let english = URL(string: "https://github.com/HandLive/handlive/blob/main/docs/privacy.md")
    public static let vietnamese = URL(string: "https://github.com/HandLive/handlive/blob/main/docs/privacy.vi.md")

    /// The Vietnamese page when the app shows Vietnamese, the English page otherwise.
    public static func url(displayLanguage: String? = Bundle.main.preferredLocalizations.first) -> URL? {
        displayLanguage?.hasPrefix("vi") == true ? vietnamese : english
    }
}
