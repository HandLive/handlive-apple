import Foundation
import HLCrypto
import HLProtocol

/// The pairing rendezvous of one QR code (PAIR-01 step 2, API 7): joined on the relay before the code is shown, so the
/// code carries `rv` only when the relay answered. The phone joins after scanning; the exchange then runs inside
/// `rv_msg` (`PairingSearch`). Close it when the code is replaced or pairing ends.
public final class PairingRendezvous: @unchecked Sendable, Equatable {
    /// 16 random bytes, `rv` of the QR code.
    public let rvId: Data
    let link: RelayLink
    let channel: RelayRendezvousChannel

    init(rvId: Data, link: RelayLink, channel: RelayRendezvousChannel) {
        self.rvId = rvId
        self.link = link
        self.channel = channel
    }

    /// Authenticates with the relay (0.6.4), opens `/v1/relay` and sends `rv_join` with a fresh `rv_id`. Throws when the
    /// relay cannot be reached: the code is then shown without `rv` and pairing stays on the LAN.
    public static func join(relay: RelayServices, timeout: Duration = .seconds(5)) async throws -> PairingRendezvous {
        let rvId = SessionHandshakeCrypto.randomNonce().prefix(16)
        let token = try await relay.api.accessToken()
        let socket = try await relay.sockets.open(token: token, timeout: timeout)
        let link = RelayLink(socket: socket)
        await link.start()
        do {
            let channel = try await link.joinRendezvous(rvId: Base64Coding.encodeB64u(Data(rvId)))
            return PairingRendezvous(rvId: Data(rvId), link: link, channel: channel)
        } catch {
            await link.close()
            throw error
        }
    }

    /// `true` once the phone joined (`rv_joined` with `peer_present`); `false` when the relay went away.
    public func waitForPhone() async -> Bool {
        await channel.waitForPeer()
    }

    public func close() async {
        await link.close()
    }

    public static func == (lhs: PairingRendezvous, rhs: PairingRendezvous) -> Bool {
        lhs.rvId == rhs.rvId
    }
}
