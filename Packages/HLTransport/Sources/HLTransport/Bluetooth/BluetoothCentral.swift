import Foundation
import HLProtocol

/// One BLE advertisement seen while scanning with the `BT_SERVICE_UUID` filter (0.4.5 "Advertisement"): the
/// peripheral's platform identifier (opaque, only meaningful to `BluetoothCentral.openChannel`) and its parsed
/// scan-response service data.
public struct BluetoothAdvertisement: Sendable, Equatable {
    public let peripheralId: String
    public let serviceData: BtAdvertisementServiceData

    public init(peripheralId: String, serviceData: BtAdvertisementServiceData) {
        self.peripheralId = peripheralId
        self.serviceData = serviceData
    }
}

/// Bluetooth power state and scan results, parallel to `DiscoveryEvent` for mDNS. A dropped L2CAP channel is not
/// reported here: it surfaces as `BluetoothChannel.receive()` throwing `ChannelClosed`, the same path LAN and
/// relay sessions already use (CONN-05 E6).
public enum BluetoothCentralEvent: Sendable, Equatable {
    case poweredOn
    case poweredOff
    /// Every advertisement currently visible (a full snapshot).
    case results([BluetoothAdvertisement])
}

/// Raw bytes to and from an open L2CAP channel — the seam `BluetoothChannel` builds the record/frame/cipher
/// layers on top of, and what a fake-central test substitutes with an in-memory pipe.
public protocol BluetoothByteStream: Sendable {
    /// Exactly `count` bytes, or throws once the stream closes (every caller always knows how many bytes it
    /// needs next: a 2-byte `rlen` prefix, then exactly `rlen` bytes of body).
    func read(_ count: Int) async throws -> Data
    func write(_ data: Data) async throws
    func close() async
}

/// Scans for phones advertising `BT_SERVICE_UUID` and opens L2CAP channels to them (0.4.5 "Advertisement",
/// CONN-05 steps 3, 5). Scanning stops when the consumer stops iterating `events()`.
public protocol BluetoothCentral: Sendable {
    func events() -> AsyncStream<BluetoothCentralEvent>
    /// Connects to the peripheral behind `peripheralId` and opens its L2CAP channel at `psm` — read from the
    /// latest advertisement, never cached, since the PSM rotates with every `BT_HINT_PERIOD`. Throws on a
    /// connect failure (CONN-05 E4); never runs the link-security handshake itself.
    func openChannel(peripheralId: String, psm: UInt16) async throws -> any BluetoothByteStream
}

/// iOS never creates a Bluetooth central (0.4.5 "Roles": only M-APP, the Mac, is the central) — this is the
/// default on iOS, where scanning never starts and a connect attempt can never happen.
public struct NullBluetoothCentral: BluetoothCentral {
    public init() {}

    public func events() -> AsyncStream<BluetoothCentralEvent> { AsyncStream { $0.finish() } }

    public func openChannel(peripheralId: String, psm: UInt16) async throws -> any BluetoothByteStream {
        throw BluetoothLinkConnectError.linkRejected
    }
}
