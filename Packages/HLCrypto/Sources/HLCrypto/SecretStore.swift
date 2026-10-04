import Foundation

/// Kho bí mật (0.2, 0.6.1): account `ik_sig`, `ik_dh`, `db_key`, `<pair_id>` (PRK từng cặp).
/// Ứng dụng dùng `KeychainSecretStore`; test dùng `InMemorySecretStore`.
public protocol SecretStore: Sendable {
    func save(_ secret: Data, account: String) throws
    func load(account: String) throws -> Data?
    func delete(account: String) throws
    /// Deletes every item of the service: a fresh install must not inherit keys the Keychain kept after the app
    /// was removed (SET-03 API 1 logic 1).
    func deleteAll() throws
    /// "Delete All HandLive Data" (SET-02 API 7): like `deleteAll()`, and on the Mac also in the other keychain, where a
    /// build signed the other way kept its own keys (logic 6).
    func deleteAllInEveryKeychain() throws
}

extension SecretStore {
    /// A store with a single keychain, or none: the same as `deleteAll()`.
    public func deleteAllInEveryKeychain() throws {
        try deleteAll()
    }
}

public enum SecretAccount {
    public static let signingKey = "ik_sig"
    public static let keyAgreementKey = "ik_dh"
    public static let databaseKey = "db_key"

    /// `PRK` của cặp lưu theo account = `pair_id`.
    public static func pairKey(pairId: String) -> String { pairId }
}

/// Kho trong bộ nhớ cho test và preview. Không bền vững.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var everyKeychainCount = 0

    /// How many times "Delete All HandLive Data" cleared the store: a fresh install's `deleteAll()` does not count.
    public var everyKeychainDeletions: Int {
        locked { everyKeychainCount }
    }

    public init() {}

    public func save(_ secret: Data, account: String) throws {
        locked { items[account] = secret }
    }

    public func load(account: String) throws -> Data? {
        locked { items[account] }
    }

    public func delete(account: String) throws {
        locked { _ = items.removeValue(forKey: account) }
    }

    public func deleteAll() throws {
        locked { items.removeAll() }
    }

    public func deleteAllInEveryKeychain() throws {
        locked {
            items.removeAll()
            everyKeychainCount += 1
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
