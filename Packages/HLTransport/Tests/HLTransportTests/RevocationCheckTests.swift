import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLTransport

/// revoke.json, receiver side: a relay revocation counts only when `by` is the phone of that pair and `sig` verifies with
/// the phone's stored `ik_sig` public key (PAIR-03 API 4, PAIR-02 API 1 logic 4).
@Suite("Revocations from the relay (revoke.json, receiver)")
struct RevocationCheckTests {
    private static func phone(pairId: String, peerDeviceId: String, peerKey: Data) -> PairedPhone {
        PairedPhone(pair: PairContext(pairId: pairId, clientDeviceId: "11111111-1111-8111-8111-111111111111",
                                      serverDeviceId: peerDeviceId, prk: Data(repeating: 1, count: 32)),
                    certificateSHA256: Data(repeating: 0xAB, count: 32), peerSigningPublicKey: peerKey)
    }

    private static func notice(_ text: String) throws -> RelayPairRevocation {
        guard case .control(.pairRevoked(let notice)) = try RelayFrame.parse(text) else {
            throw VectorError.malformed("pair_revoked")
        }
        return notice
    }

    @Test("Each valid statement is accepted by the peer it names, and only for its own pair")
    func validStatements() throws {
        for vector in try VectorFile("revoke.json").vectors {
            let notice = try Self.notice(try vector.string("pair_revoked"))
            let peer = Self.phone(pairId: try vector.string("pair_id"), peerDeviceId: try vector.string("device_id"),
                                  peerKey: try vector.hex("ik_sig_pub"))
            #expect(peer.acceptsRevocation(notice), "\(vector.label)")
            let otherPair = Self.phone(pairId: "0192f3d8-2b11-4c42-8e5a-6b7c8d9e0f12",
                                       peerDeviceId: try vector.string("device_id"), peerKey: try vector.hex("ik_sig_pub"))
            #expect(!otherPair.acceptsRevocation(notice), "\(vector.label)")
        }
    }

    @Test("Every receiver invalid vector is ignored")
    func invalidStatements() throws {
        let receiver = try VectorFile("revoke.json").invalidVectors.filter { $0["check"] as? String == "receiver" }
        #expect(receiver.count >= 7)
        for vector in receiver {
            let peer = Self.phone(pairId: try vector.string("pair_id"), peerDeviceId: try vector.string("peer_device_id"),
                                  peerKey: try vector.hex("peer_ik_sig_pub"))
            #expect(!peer.acceptsRevocation(try Self.notice(try vector.string("pair_revoked"))), "\(vector.label)")
        }
    }

    @Test("A GET /v1/pairs row carries the same statement")
    func pairListRow() throws {
        let vector = try #require(try VectorFile("revoke.json").vectors.first)
        let peer = Self.phone(pairId: try vector.string("pair_id"), peerDeviceId: try vector.string("device_id"),
                              peerKey: try vector.hex("ik_sig_pub"))
        let row = RelayPairEntry(pairId: try vector.string("pair_id"), peerDeviceId: try vector.string("device_id"),
                                 peerPlatform: .macos, createdAt: 1, revokedAt: try vector.int("revoked_at"),
                                 revokedBy: try vector.string("device_id"), revokeSig: try vector.string("sig_b64u"),
                                 peerOnline: false)
        #expect(peer.acceptsRevocation(row.revocation))
        let unsigned = RelayPairEntry(pairId: row.pairId, peerDeviceId: row.peerDeviceId, peerPlatform: .macos,
                                      createdAt: 1, revokedAt: row.revokedAt, peerOnline: false)
        #expect(!peer.acceptsRevocation(unsigned.revocation))
    }
}
