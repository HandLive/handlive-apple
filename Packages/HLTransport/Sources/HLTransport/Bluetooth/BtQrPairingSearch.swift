import Foundation

/// Why `BtQrPairingSearch.run` gave up without pairing (PAIR-01 flow B, step 7 "Waits up to 20 s"; E3/E11).
public enum BtQrPairingSearchError: Error, Equatable, Sendable {
    /// No advertiser of this QR's `pr_bt` completed the link-security handshake before `overallTimeout`: every
    /// candidate either never appeared, or failed `BluetoothLinkConnector.connect` (a copied advertisement, a
    /// phone that is not this one, or the window already closed on the phone).
    case timedOut
}

/// PAIR-01 flow B over Bluetooth (0.4.5 "Pairing mode", PAIR-01 steps B1–B4) — QR only, no CPace: flow C (the PIN)
/// is `#218`. Scans `central` for the pairing hint `pr_bt` derived from this QR's `pairing_secret`, tries every
/// matching advertiser's L2CAP channel through `BluetoothLinkConnector` (psk = `K_bt_plink`), then runs the
/// unchanged `PairingExchange` over the resulting secured `BluetoothChannel` — the same pin-and-store path the LAN
/// search (`PairingSearch`) already uses. Reuses `CoreBluetoothCentral`/`BluetoothChannel` from SP1; never touches
/// `HLCrypto` beyond its already-public HKDF/HMAC primitives (CPace stays `#218`'s).
public struct BtQrPairingSearch: Sendable {
    public let central: any BluetoothCentral
    /// PAIR-01 step 7: "Waits up to 20 s" before giving up (E3).
    public var overallTimeout: Duration = .seconds(20)
    /// Seam for tests: defaults to the real `BluetoothLinkConnector.connect`. Substituting it lets a test exercise
    /// the scan/candidate/hand-off logic below without a real Noise round trip, which `BluetoothLinkConnectorTests`
    /// and the `bt-pairing.json` vector already cover on their own.
    var connectLink: @Sendable (_ stream: any BluetoothByteStream, _ psk: Data) async throws -> BluetoothChannel = {
        try await BluetoothLinkConnector.connect(stream: $0, psk: $1)
    }

    public init(central: any BluetoothCentral) {
        self.central = central
    }

    /// Runs one search for `pairingSecret`'s window. Throws `BtQrPairingSearchError.timedOut`, or whatever
    /// `PairingExchange.run` throws once a candidate's link has secured (`PairingFailure`): past that point the
    /// link holds the pairing window (0.4.5 "Pairing link"), so the failure is not retried on another candidate.
    public func run(identity: PairingIdentity, pairingSecret: Data,
                    offerTimeout: Duration) async throws -> PairingResult {
        let keys = BtQrPairingKeys.derive(pairingSecret: pairingSecret)
        let exchange = PairingExchange(identity: identity, credential: .qr(secret: pairingSecret),
                                       offerTimeout: offerTimeout)
        return try await withThrowingTaskGroup(of: PairingResult.self) { group in
            group.addTask { try await search(keys: keys, exchange: exchange) }
            group.addTask {
                try await Task.sleep(for: overallTimeout)
                throw BtQrPairingSearchError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw BtQrPairingSearchError.timedOut }
            return result
        }
    }

    /// Scans until a candidate's channel secures and `PairingExchange` returns, or `central.events()` itself ends
    /// (cancellation from the lost race against `overallTimeout` in `run`). `tried` is never reset: a copied
    /// advertisement that already failed key confirmation is not retried (0.4.5 "Several advertisers... are tried
    /// one after the other").
    private func search(keys: BtQrPairingKeys, exchange: PairingExchange) async throws -> PairingResult {
        var tried = Set<String>()
        for await event in central.events() {
            guard case .results(let advertisements) = event else { continue }
            for candidate in advertisements
            where !tried.contains(candidate.peripheralId) && candidate.serviceData.hints.contains(keys.advertisingHint) {
                tried.insert(candidate.peripheralId)
                if let result = try await attempt(candidate: candidate, keys: keys, exchange: exchange) {
                    return result
                }
            }
        }
        throw BtQrPairingSearchError.timedOut
    }

    /// `nil` only for a pre-auth failure (open/connect, E11): the caller tries the next candidate. A
    /// `PairingExchange` failure past that point propagates instead (the link already holds the window).
    private func attempt(candidate: BluetoothAdvertisement, keys: BtQrPairingKeys,
                         exchange: PairingExchange) async throws -> PairingResult? {
        let secured: BluetoothChannel
        do {
            let stream = try await central.openChannel(peripheralId: candidate.peripheralId,
                                                        psm: candidate.serviceData.psm)
            secured = try await connectLink(stream, keys.linkKey)
        } catch {
            return nil
        }
        return try await exchange.run(over: secured, certificateSHA256: nil)
    }
}
