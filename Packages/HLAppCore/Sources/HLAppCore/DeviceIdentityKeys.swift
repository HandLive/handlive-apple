import Foundation
import HLCrypto
import HLProtocol

/// This device's long-term keys (0.6.1): `ik_sig` (Ed25519 seed), `ik_dh` (X25519), `db_key` (32 random bytes),
/// all in the Keychain, and the self-certifying `device_id` derived from `ik_sig` (0.2, C4).
public struct DeviceIdentityKeys: Sendable, Equatable {
    public let signingSeed: Data
    public let keyAgreementPrivateKey: Data
    public let databaseKey: Data
    public let signingPublicKey: Data
    public let keyAgreementPublicKey: Data
    public let deviceId: String

    init(signingSeed: Data, keyAgreementPrivateKey: Data, databaseKey: Data) throws {
        self.signingSeed = signingSeed
        self.keyAgreementPrivateKey = keyAgreementPrivateKey
        self.databaseKey = databaseKey
        signingPublicKey = try Ed25519.publicKey(seed: signingSeed)
        keyAgreementPublicKey = try X25519.publicKey(privateKey: keyAgreementPrivateKey)
        deviceId = try DeviceIdentity.deviceId(signingPublicKey: signingPublicKey)
    }

    /// SET-03 step 2 and API 1: a fresh install (no `setup.started_at`) first clears what the Keychain kept from an
    /// earlier install, then creates the three keys; later launches load them. Throws on any Keychain error (E1).
    public static func loadOrCreate(secrets: any SecretStore, settings: AppSettings,
                                    now: Int64 = HLUUID.currentTimeMs()) throws -> DeviceIdentityKeys {
        if settings.setupStartedAt == nil {
            try secrets.deleteAll()
            let keys = try DeviceIdentityKeys(signingSeed: Ed25519.generateSeed(),
                                              keyAgreementPrivateKey: X25519.generatePrivateKey(),
                                              databaseKey: SessionHandshakeCrypto.randomNonce())
            try secrets.save(keys.signingSeed, account: SecretAccount.signingKey)
            try secrets.save(keys.keyAgreementPrivateKey, account: SecretAccount.keyAgreementKey)
            try secrets.save(keys.databaseKey, account: SecretAccount.databaseKey)
            settings.setupStartedAt = now
            return keys
        }
        guard let seed = try secrets.load(account: SecretAccount.signingKey),
              let agreement = try secrets.load(account: SecretAccount.keyAgreementKey),
              let database = try secrets.load(account: SecretAccount.databaseKey)
        else { throw IdentityError.keysMissing }
        return try DeviceIdentityKeys(signingSeed: seed, keyAgreementPrivateKey: agreement, databaseKey: database)
    }
}

public enum IdentityError: Error, Equatable {
    /// `setup.started_at` is set but a key is gone (Keychain reset): setup must start over.
    case keysMissing
}
