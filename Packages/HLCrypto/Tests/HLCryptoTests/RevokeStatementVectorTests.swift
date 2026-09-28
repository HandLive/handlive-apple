import Foundation
import HLProtocol
import Testing
@testable import HLCrypto

/// revoke.json: the `HLREVOKE1` statement of 0.6.2 (PAIR-03 API 3 and 4, SET-02 API 2).
@Suite("Revoke statement vectors (HLREVOKE1)")
struct RevokeStatementVectorTests {
    @Test("Message bytes match; the vector signature and a fresh one verify with the revoking device's key")
    func validVectors() throws {
        let file = try VectorFile("revoke.json")
        #expect(file.vectors.count >= 3)
        for vector in file.vectors {
            let seed = try vector.hex("ik_sig_seed")
            let publicKey = try vector.hex("ik_sig_pub")
            let pairId = try vector.string("pair_id")
            let by = try vector.string("device_id")
            let revokedAt = try vector.int("revoked_at")
            let message = try RevokeStatement.message(pairId: pairId, by: by, revokedAt: revokedAt)
            #expect(message == (try vector.hex("message")), "\(vector["name"] ?? "")")
            #expect(RevokeStatement.verify(try vector.hex("sig"), pairId: pairId, by: by, revokedAt: revokedAt,
                                           publicKey: publicKey))
            let fresh = try RevokeStatement.sign(pairId: pairId, by: by, revokedAt: revokedAt, seed: seed)
            #expect(fresh.count == 64)
            #expect(RevokeStatement.verify(fresh, pairId: pairId, by: by, revokedAt: revokedAt, publicKey: publicKey))
            #expect(Base64Coding.encodeB64u(try vector.hex("sig")) == (try vector.string("sig_b64u")))
        }
    }

    @Test("A statement of another time, pair or signer does not verify")
    func tampered() throws {
        let vector = try #require(try VectorFile("revoke.json").vectors.first)
        let pairId = try vector.string("pair_id")
        let by = try vector.string("device_id")
        let revokedAt = try vector.int("revoked_at")
        let sig = try vector.hex("sig")
        let key = try vector.hex("ik_sig_pub")
        #expect(!RevokeStatement.verify(sig, pairId: pairId, by: by, revokedAt: revokedAt + 1, publicKey: key))
        #expect(!RevokeStatement.verify(sig, pairId: "7a1e2b3c-4d5e-4f60-9172-83a4b5c6d7e8", by: by,
                                        revokedAt: revokedAt, publicKey: key))
        #expect(!RevokeStatement.verify(sig, pairId: pairId, by: by, revokedAt: revokedAt,
                                        publicKey: try vector.hex("peer_ik_sig_pub")))
        #expect(!RevokeStatement.verify(sig.prefix(63), pairId: pairId, by: by, revokedAt: revokedAt, publicKey: key))
        #expect(!RevokeStatement.verify(sig, pairId: "not-a-uuid", by: by, revokedAt: revokedAt, publicKey: key))
    }
}
