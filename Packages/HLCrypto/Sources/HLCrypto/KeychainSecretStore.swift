import Foundation
import Security

/// Keychain: `kSecClassGenericPassword`, service `app.handlive.keys`,
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (0.6.1, C3). Trên macOS dùng data-protection keychain
/// (cần ứng dụng đã ký có keychain access group; tiến trình test không ký sẽ nhận lỗi -34018). An ad-hoc signed Mac
/// build without that entitlement uses the login keychain instead (0.6.1): same items, no accessibility class.
public struct KeychainSecretStore: SecretStore {
    public static let service = "app.handlive.keys"
    /// iOS/iPadOS: the App Group `group.app.handlive`, which doubles as the keychain access group the app shares with
    /// its Notification Service Extension (SET-03 API 1, CONN-04 step 9b); `nil` keeps the app's default group (Mac).
    public let accessGroup: String?
    /// macOS: the data-protection keychain (`true`) or the login keychain. Always `true` on iOS, whose only keychain it is.
    public let usesDataProtectionKeychain: Bool

    public init(accessGroup: String? = nil) {
        self.init(accessGroup: accessGroup, usesDataProtectionKeychain: Self.processCanUseDataProtectionKeychain)
    }

    init(accessGroup: String?, usesDataProtectionKeychain: Bool) {
        self.accessGroup = accessGroup
        self.usesDataProtectionKeychain = usesDataProtectionKeychain
    }

    /// Read once from this process's code signature (0.6.1): only an app signed with a team carries a keychain access
    /// group, and without one the data-protection keychain answers errSecMissingEntitlement to every call.
    public static let processCanUseDataProtectionKeychain: Bool = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return canUseDataProtectionKeychain { SecTaskCopyValueForEntitlement(task, $0 as CFString, nil) }
        #else
        return true
        #endif
    }()

    /// `keychain-access-groups`, or the application identifier, which is an implicit access group of its own.
    static func canUseDataProtectionKeychain(entitlement: (String) -> Any?) -> Bool {
        entitlement("keychain-access-groups") != nil || entitlement("com.apple.application-identifier") != nil
    }

    func baseQuery(account: String) -> [String: Any] {
        matchQuery(account: account, dataProtectionKeychain: usesDataProtectionKeychain)
    }

    /// One account, or every item of the service (`account == nil`), in the data-protection or the login keychain. The
    /// flag is explicit on macOS: left out, a team-signed process's query matches its data-protection items too.
    func matchQuery(account: String? = nil, dataProtectionKeychain: Bool) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service]
        if let account { query[kSecAttrAccount as String] = account }
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = dataProtectionKeychain
        #endif
        return query
    }

    func addQuery(_ secret: Data, account: String) -> [String: Any] {
        var query = baseQuery(account: account)
        query[kSecValueData as String] = secret
        // The login keychain has no accessibility classes: the class belongs to the data-protection keychain only.
        if usesDataProtectionKeychain {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        return query
    }

    public func save(_ secret: Data, account: String) throws {
        try delete(account: account)
        try check(SecItemAdd(addQuery(secret, account: account) as CFDictionary, nil))
    }

    public func load(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return result as? Data
    }

    /// This build's keychain only: a fresh install keeps what a build signed the other way stored in the other keychain,
    /// so switching back to it finds its keys again (SET-03 API 1 logic 1).
    public func deleteAll() throws {
        try deleteItems(dataProtectionKeychain: usesDataProtectionKeychain)
    }

    /// "Delete All HandLive Data" (SET-02 API 7 logic 6): this build's keychain, then on macOS the other one, where a
    /// build signed the other way (ad hoc ↔ team) kept its own keys. An ad-hoc build cannot reach the data-protection
    /// keychain: errSecMissingEntitlement there leaves a team build's device-only keys in place.
    public func deleteAllInEveryKeychain() throws {
        try deleteAll()
        #if os(macOS)
        do {
            try deleteItems(dataProtectionKeychain: !usesDataProtectionKeychain)
        } catch CryptoError.keychain(status: errSecMissingEntitlement) {}
        #endif
    }

    public func delete(account: String) throws {
        try deleteItems(account: account, dataProtectionKeychain: usesDataProtectionKeychain)
    }

    /// Missing items count as deleted. The data-protection keychain deletes every match in one call; the login keychain
    /// goes through `LoginKeychain`, since `SecItemDelete` refuses the items another build created there (0.6.1).
    func deleteItems(account: String? = nil, dataProtectionKeychain: Bool) throws {
        let query = matchQuery(account: account, dataProtectionKeychain: dataProtectionKeychain)
        #if os(macOS)
        if !dataProtectionKeychain { return try LoginKeychain.deleteItems(matching: query) }
        #endif
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw CryptoError.keychain(status: status) }
    }
}
