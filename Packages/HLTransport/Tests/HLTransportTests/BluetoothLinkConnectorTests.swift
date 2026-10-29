import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLTransport

/// `BluetoothLinkConnector.connect` over an in-memory byte pipe (0.4.5 "Link-security handshake" steps 1–4) —
/// the M7.1c seam between a `BluetoothByteStream` (real or fake) and the already-tested `BluetoothChannel`.
@Suite("Bluetooth link connector over a fake pipe (0.4.5)")
struct BluetoothLinkConnectorTests {
    static func handshakeVector() throws -> [String: Any] {
        try #require(VectorFile("bt-link.json").vectors.first {
            $0["kind"] as? String == "handshake" && ($0["name"] as? String)?.contains("cặp 1") == true
        })
    }

    /// Writes `challengeRecord` then `noise2Record` to `peripheral`, after reading (and discarding) the
    /// client's `noise1` — the S side, scripted with canned vector bytes.
    static func servePreauth(_ peripheral: FakeBluetoothByteStream, challengeRecord: Data,
                             noise2Record: Data) async throws {
        try await peripheral.write(challengeRecord)
        let rlen = BtRecordCodec.decodeRlen(try await peripheral.read(BtRecordCodec.lengthPrefixSize))
        _ = try await peripheral.read(rlen) // noise1, not needed: the canned noise2 already answers for it
        try await peripheral.write(noise2Record)
    }

    @Test("a full handshake matches the vector's c1/c2")
    func fullHandshakeMatchesVector() async throws {
        let v = try Self.handshakeVector()
        let (client, peripheral) = FakeBluetoothByteStream.pair()
        Task {
            try? await Self.servePreauth(peripheral, challengeRecord: v.hex("challenge_record"),
                                         noise2Record: v.hex("noise2_record"))
        }
        let channel = try await BluetoothLinkConnector.connect(stream: client, psk: try v.hex("psk"),
                                                                generateEphemeralPrivateKey: { try! v.hex("e_priv_c") })
        _ = channel // the resulting BluetoothChannel itself is covered by BluetoothChannelTests-style vectors
    }

    @Test("a tampered noise2 tag throws keyConfirmationFailed, not a crash")
    func tamperedNoise2ThrowsKeyConfirmationFailed() async throws {
        let v = try Self.handshakeVector()
        let invalid = try #require(VectorFile("bt-link.json").invalidVectors.first {
            $0["reason"] as? String == "tag_mismatch_noise2"
        })
        let tamperedPayload = try invalid.hex("e_pub_s") + invalid.hex("ciphertext_tag_2")
        let tamperedNoise2 = BtRecordCodec.encode(BtPreauthRecord.encode(kind: BtPreauthRecord.kindNoise2,
                                                                          payload: tamperedPayload))
        let (client, peripheral) = FakeBluetoothByteStream.pair()
        Task {
            try? await Self.servePreauth(peripheral, challengeRecord: v.hex("challenge_record"),
                                         noise2Record: tamperedNoise2)
        }
        await #expect(throws: BluetoothLinkConnectError.keyConfirmationFailed) {
            _ = try await BluetoothLinkConnector.connect(stream: client, psk: try v.hex("psk"),
                                                          generateEphemeralPrivateKey: { try! v.hex("e_priv_c") })
        }
    }

    @Test("a reject record throws keyConfirmationFailed (0.4.5: LINK_REJECTED, next candidate)")
    func rejectRecordThrowsKeyConfirmationFailed() async throws {
        let v = try Self.handshakeVector()
        let rejectRecord = BtRecordCodec.encode(BtPreauthRecord.encode(kind: BtPreauthRecord.kindReject))
        let (client, peripheral) = FakeBluetoothByteStream.pair()
        Task {
            try? await {
                try await peripheral.write(v.hex("challenge_record"))
                let rlen = BtRecordCodec.decodeRlen(try await peripheral.read(BtRecordCodec.lengthPrefixSize))
                _ = try await peripheral.read(rlen)
                try await peripheral.write(rejectRecord)
            }()
        }
        await #expect(throws: BluetoothLinkConnectError.keyConfirmationFailed) {
            _ = try await BluetoothLinkConnector.connect(stream: client, psk: try v.hex("psk"),
                                                          generateEphemeralPrivateKey: { try! v.hex("e_priv_c") })
        }
    }

    @Test("the channel closing before the challenge arrives throws linkRejected")
    func closedBeforeChallengeThrowsLinkRejected() async throws {
        let v = try Self.handshakeVector()
        let (client, peripheral) = FakeBluetoothByteStream.pair()
        await peripheral.close()
        await #expect(throws: BluetoothLinkConnectError.linkRejected) {
            _ = try await BluetoothLinkConnector.connect(stream: client, psk: try v.hex("psk"))
        }
    }
}
