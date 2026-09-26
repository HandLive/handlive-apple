import Foundation
import HLProtocol

/// Names of conversations as the list, bubbles and notifications show them (SMS-02 field 1, SMS-03 field 2).
public enum SmsNames {
    /// The contact name, or the numbers in national format joined with ", " (group conversations).
    public static func title(displayName: String?, addresses: [String]) -> String {
        if let displayName, !displayName.isEmpty { return displayName }
        return addresses.map(PhoneNumberDisplay.format).joined(separator: ", ")
    }

    public static func title(of thread: SmsThreadData) -> String {
        title(displayName: thread.displayName, addresses: thread.addresses)
    }
}

/// Phone numbers for display. Vietnamese numbers (`+84…`) are shown in national format, "090 000 0123", as the design
/// system writes them; other numbers keep the form the phone sent (E.164, a short code or a sender name). The apps have
/// no libphonenumber; the phone normalizes numbers, the Mac and iPhone only display them.
public enum PhoneNumberDisplay {
    public static func format(_ address: String) -> String {
        guard address.hasPrefix("+84") else { return address }
        let digits = address.dropFirst(3)
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }), (8...10).contains(digits.count) else { return address }
        let national = "0" + digits
        let groups: [Int] = switch national.count {
        case 10: [3, 3, 4]
        case 11: [3, 4, 4]
        default: [national.count]
        }
        var result: [String] = []
        var rest = Substring(national)
        for size in groups {
            result.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return result.joined(separator: " ")
    }
}
