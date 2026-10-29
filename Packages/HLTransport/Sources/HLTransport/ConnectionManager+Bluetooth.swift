import Foundation
import HLCrypto
import HLProtocol

extension ConnectionManager {
    /// Tries each Bluetooth advertisement with a matching hint in turn (CONN-05 steps 3, 5): opens its L2CAP
    /// channel, runs the link-security handshake, then the session handshake. `machine.state` is already
    /// `.connectingBT` (the caller applied `.bluetoothInstanceFound`). On `keyConfirmationFailed` the next
    /// candidate is tried at once (E3: "when several advertisers carry the hint, the next attempt tries another
    /// one") before giving up to `Backoff`.
    func connectBluetooth(phone: PairedPhone) async {
        let psk = BtLinkKeyDerivation.kBtLink(prk: phone.pair.prk)
        var tried = Set<String>()
        while true {
            guard let candidate = matchingBluetoothCandidates().first(where: { !tried.contains($0.peripheralId) })
            else {
                scheduleBackoff(.backoff)
                apply(.bluetoothConnectFailed)
                return
            }
            tried.insert(candidate.peripheralId)
            do {
                let stream = try await bluetooth.openChannel(peripheralId: candidate.peripheralId,
                                                              psm: candidate.serviceData.psm)
                let channel = try await BluetoothLinkConnector.connect(
                    stream: stream, psk: psk, generateEphemeralPrivateKey: bluetoothEphemeralKey)
                apply(.linkSecurityVerified)
                do {
                    let established = try await ControlSession.establish(
                        over: channel, pair: phone.pair, localCapability: localCapability, route: .bluetooth,
                        configuration: configuration.session)
                    await adopt(established, host: nil, port: nil)
                } catch {
                    handshakeFailed(error, route: .bluetooth)
                }
                return
            } catch BluetoothLinkConnectError.keyConfirmationFailed {
                continue
            } catch {
                scheduleBackoff(.backoff)
                apply(.bluetoothConnectFailed)
                return
            }
        }
    }
}
