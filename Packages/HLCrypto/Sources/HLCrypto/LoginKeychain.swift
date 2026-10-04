#if os(macOS)
import Foundation
import Security

/// Deletes from the login keychain, the only keychain of an ad-hoc signed Mac build (0.6.1). `SecItemDelete` answers
/// errSecInvalidOwnerEdit (-25244) for an item another code signature created — an earlier ad-hoc build, or the ad-hoc
/// build seen from a team build — so an update could neither erase nor start over without its predecessor's keys. The
/// items are found by reference instead and deleted with `SecKeychainItemDelete`, which removes them without a dialog
/// (measured on macOS 27). That call is deprecated since macOS 10.10 but nothing replaces it for this; it stays here.
enum LoginKeychain {
    /// `query` is a `SecItem` match with `kSecUseDataProtectionKeychain = false`; missing items count as deleted.
    static func deleteItems(matching query: [String: Any]) throws {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(referenceQuery(query) as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        try check(status)
        for item in result as? [SecKeychainItem] ?? [] {
            let deleted = SecKeychainItemDelete(item)
            if deleted != errSecItemNotFound { try check(deleted) }
        }
    }

    /// Every match, as a reference to the item.
    static func referenceQuery(_ query: [String: Any]) -> [String: Any] {
        var references = query
        references[kSecMatchLimit as String] = kSecMatchLimitAll
        references[kSecReturnRef as String] = true
        return references
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw CryptoError.keychain(status: status) }
    }
}
#endif
