import Foundation
import HLCrypto

/// The keys of the dev client in files of its scratch directory (0600), instead of the data-protection Keychain the
/// signed app uses: an unsigned command line tool has no keychain access group.
final class FileSecretStore: SecretStore, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    func save(_ secret: Data, account: String) throws {
        try lock.withLock {
            let url = file(account)
            try secret.base64EncodedData().write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func load(account: String) throws -> Data? {
        try lock.withLock {
            let url = file(account)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Data(base64Encoded: try Data(contentsOf: url))
        }
    }

    func delete(account: String) throws {
        try lock.withLock {
            let url = file(account)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    func deleteAll() throws {
        try lock.withLock {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Accounts are key names or `pair_id`s; anything else is refused rather than used as a path.
    private func file(_ account: String) -> URL {
        let safe = account.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } ? account : "invalid"
        return directory.appendingPathComponent("\(safe).key")
    }
}
