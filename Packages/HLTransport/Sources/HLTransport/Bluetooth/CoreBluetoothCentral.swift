import CoreBluetooth
import Foundation
import HLProtocol

/// `BluetoothCentral` over real CoreBluetooth (0.4.5 "Roles": M-APP is the central) — scans for
/// `BT_SERVICE_UUID`, reads the PSM and hints from the scan response, and opens L2CAP channels on request.
/// **Not measured on a real device yet** (M7.1c Gói B): `NSBluetoothAlwaysUsageDescription` is M7.7a's, so
/// `CBCentralManager` cannot even start scanning on the Mac until that Info.plist entry lands.
public final class CoreBluetoothCentral: NSObject, BluetoothCentral, CBCentralManagerDelegate, CBPeripheralDelegate,
                                          @unchecked Sendable {
    /// `BT_SERVICE_UUID` (0.4.5, 00-common-specs 0.10): self-generated 128-bit UUID, not the spike's `0xFEED`.
    public static let serviceUUID = CBUUID(string: "3b3a01f9-ab27-44a8-bb68-b9b11a488bdb")

    private var manager: CBCentralManager!
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<BluetoothCentralEvent>.Continuation] = [:]
    private var peripherals: [String: CBPeripheral] = [:]
    private var advertisements: [String: BtAdvertisementServiceData] = [:]
    private var pendingPSM: [String: UInt16] = [:]
    private var openContinuations: [String: CheckedContinuation<any BluetoothByteStream, Error>] = [:]

    override public init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    public func events() -> AsyncStream<BluetoothCentralEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            let poweredOn = manager.state == .poweredOn
            let snapshot = results()
            lock.unlock()
            if poweredOn {
                continuation.yield(.poweredOn)
                continuation.yield(.results(snapshot))
            }
            continuation.onTermination = { [weak self] _ in self?.forget(id) }
            if manager.state == .poweredOn { manager.scanForPeripherals(withServices: [Self.serviceUUID], options: nil) }
        }
    }

    public func openChannel(peripheralId: String, psm: UInt16) async throws -> any BluetoothByteStream {
        guard let peripheral = reservePeripheral(peripheralId, psm: psm) else {
            throw BluetoothLinkConnectError.linkRejected
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.registerOpenContinuation(peripheralId, continuation)
            peripheral.delegate = self
            manager.connect(peripheral, options: nil)
        }
    }

    private func reservePeripheral(_ peripheralId: String, psm: UInt16) -> CBPeripheral? {
        lock.lock()
        defer { lock.unlock() }
        guard let peripheral = peripherals[peripheralId] else { return nil }
        pendingPSM[peripheralId] = psm
        return peripheral
    }

    private func registerOpenContinuation(_ peripheralId: String,
                                           _ continuation: CheckedContinuation<any BluetoothByteStream, Error>) {
        lock.lock()
        openContinuations[peripheralId] = continuation
        lock.unlock()
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            broadcast(.poweredOn)
            manager.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
        case .poweredOff, .unauthorized, .unsupported, .resetting, .unknown:
            lock.lock()
            peripherals.removeAll()
            advertisements.removeAll()
            lock.unlock()
            broadcast(.poweredOff)
        @unknown default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                advertisementData: [String: Any], rssi: NSNumber) {
        guard let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
              let bytes = serviceData[Self.serviceUUID], let parsed = BtAdvertisementServiceData.decode(bytes)
        else { return }
        let id = peripheral.identifier.uuidString
        lock.lock()
        peripherals[id] = peripheral
        advertisements[id] = parsed
        let snapshot = results()
        lock.unlock()
        broadcast(.results(snapshot))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier.uuidString
        lock.lock()
        let psm = pendingPSM[id]
        lock.unlock()
        guard let psm else { return }
        peripheral.openL2CAPChannel(CBL2CAPPSM(psm))
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        failOpen(peripheral.identifier.uuidString, error: error ?? BluetoothLinkConnectError.linkRejected)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                error: Error?) {
        // A dropped L2CAP channel surfaces through `BluetoothChannel.receive()` throwing `ChannelClosed`
        // (CONN-05 E6) — this callback only forgets the advertisement, so a stale PSM is never reused.
        let id = peripheral.identifier.uuidString
        lock.lock()
        peripherals.removeValue(forKey: id)
        advertisements.removeValue(forKey: id)
        let snapshot = results()
        lock.unlock()
        broadcast(.results(snapshot))
        failOpen(id, error: error ?? BluetoothLinkConnectError.linkRejected)
    }

    // MARK: - CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        let id = peripheral.identifier.uuidString
        guard let channel else {
            failOpen(id, error: error ?? BluetoothLinkConnectError.linkRejected)
            return
        }
        lock.lock()
        let continuation = openContinuations.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(returning: CoreBluetoothL2CAPStream(channel: channel))
    }

    // MARK: - Private

    private func results() -> [BluetoothAdvertisement] {
        advertisements.map { BluetoothAdvertisement(peripheralId: $0.key, serviceData: $0.value) }
    }

    private func broadcast(_ event: BluetoothCentralEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        targets.forEach { $0.yield(event) }
    }

    private func forget(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }

    private func failOpen(_ peripheralId: String, error: Error) {
        lock.lock()
        let continuation = openContinuations.removeValue(forKey: peripheralId)
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}
