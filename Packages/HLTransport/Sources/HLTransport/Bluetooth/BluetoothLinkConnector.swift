import Foundation
import HLCrypto
import HLProtocol

/// Why `BluetoothLinkConnector.connect` failed (0.4.5 "Link-security handshake" steps 1–4).
public enum BluetoothLinkConnectError: Error, Equatable, Sendable {
    /// `noise2`'s tag check failed, or the peripheral sent `reject` (0.4.5 step 4) — CONN-05 E3: when several
    /// advertisers carry the matched hint, try another one instead of backing off at once.
    case keyConfirmationFailed
    /// A pre-auth record violated a 0.4.5 bound, the stream closed, or an unexpected record kind arrived —
    /// CONN-05 E4: back off on the normal schedule.
    case linkRejected
}

/// Runs steps 1–4 of the link-security handshake (0.4.5) over an already-open `BluetoothByteStream` and returns
/// the resulting `BluetoothChannel`. The caller (`ConnectionManager`) decides what follows a failure: another
/// candidate advertiser (`keyConfirmationFailed`, CONN-05 E3) or `Backoff` (`linkRejected`, E4).
enum BluetoothLinkConnector {
    static func connect(stream: any BluetoothByteStream, psk: Data,
                        generateEphemeralPrivateKey: @escaping @Sendable () -> Data = { X25519.generatePrivateKey() })
    async throws -> BluetoothChannel {
        let client = BluetoothLinkSecurityClient(generateEphemeralPrivateKey: generateEphemeralPrivateKey)
        let challenge = try await readPreauthRecord(stream)
        guard challenge.kind == BtPreauthRecord.kindChallenge else { throw BluetoothLinkConnectError.linkRejected }
        client.receiveChallenge(nS: challenge.payload)

        let noise1Body = try client.buildNoise1(psk: psk)
        do {
            try await stream.write(BtRecordCodec.encode(noise1Body))
        } catch {
            throw BluetoothLinkConnectError.linkRejected
        }

        let noise2 = try await readPreauthRecord(stream)
        guard noise2.kind != BtPreauthRecord.kindReject else { throw BluetoothLinkConnectError.keyConfirmationFailed }
        guard noise2.kind == BtPreauthRecord.kindNoise2 else { throw BluetoothLinkConnectError.linkRejected }
        guard let keys = client.receiveNoise2(message2: noise2.payload) else {
            throw BluetoothLinkConnectError.keyConfirmationFailed
        }
        return BluetoothChannel(stream: stream, sealKey: keys.c1, openKey: keys.c2)
    }

    /// `rlen` (checked against `BT_PREAUTH_RECORD_MAX` before allocating, review #165) then the pre-auth body.
    static func readPreauthRecord(_ stream: any BluetoothByteStream) async throws -> BtPreauthRecord.Decoded {
        do {
            let rlen = BtRecordCodec.decodeRlen(try await stream.read(BtRecordCodec.lengthPrefixSize))
            try BtRecordCodec.requireWithinBound(rlen, maxBodySize: BtLinkConstants.preauthRecordMax)
            return try BtPreauthRecord.decode(try await stream.read(rlen))
        } catch {
            throw BluetoothLinkConnectError.linkRejected
        }
    }
}
