import Foundation
import HLAppCore
import HLCalls
import HLProtocol
import HLSMS
import HLTransport

/// The connection part of the Mac app model, headless: the real `ConnectionManager` (handshake, capability exchange,
/// keep-alive, `RECONNECT_BACKOFF`) with the pair and the forwarded address, and the engines the apps run —
/// `CallController`, `CallLogEngine`, `SmsEngine`, `ClipboardEngine` — fed with the link events as `AppModel` feeds them.
@MainActor
final class DevLink {
    let workspace: DevWorkspace
    let manager: ConnectionManager
    let calls = CallController()
    let callLog: CallLogEngine
    let callStore: CallLogStore
    let sms: SmsEngine
    let smsStore: SmsStore
    let clipboard: ClipboardEngine
    let pasteboard = MemoryPasteboard()
    let log = DevEventLog()
    /// `listen` prints every decoded message; the other commands print only what they ask for.
    var verbose = true
    private(set) var session: ControlSession?
    private(set) var peerCapability: CapabilityData?
    private var events: Task<Void, Never>?

    init(workspace: DevWorkspace) throws {
        self.workspace = workspace
        let options = workspace.options
        let database = try workspace.openDatabase()
        smsStore = SmsStore(database: database)
        sms = SmsEngine(store: smsStore)
        callStore = CallLogStore(database: database)
        callLog = CallLogEngine(store: callStore)
        clipboard = ClipboardEngine(access: pasteboard, settings: workspace.settings, deviceId: workspace.keys.deviceId,
                                    deviceName: workspace.device.name, readingAllowed: { true },
                                    temporaryDirectory: options.scratch.appendingPathComponent("clip", isDirectory: true))
        manager = ConnectionManager(localCapability: workspace.device.capability(settings: workspace.settings),
                                    discovery: ForwardedDiscovery(host: options.host, port: options.port),
                                    network: SteadyNetwork(),
                                    connector: ForwardedConnector(host: options.host, port: options.port))
        wireEngines()
    }

    private func wireEngines() {
        let settings = workspace.settings
        sms.enabledHere = { settings.smsEnabled }
        sms.notifyEnabled = { false }
        sms.onEvent = { [weak self] event in
            if case .syncStatus(let status) = event { self?.log.append(.smsSync(status)) }
        }
        calls.enabledHere = { settings.callsEnabled }
        calls.onEvent = { [weak self] event in
            if case .missed(let missed) = event { self?.log.append(.missedCall(missed)) }
        }
        callLog.enabledHere = { settings.callsEnabled }
        callLog.notifyEnabled = { true }
        callLog.onEvent = { [weak self] event in
            switch event {
            case .status(let status): self?.log.append(.callLogStatus(status))
            case .missed(let missed): self?.log.append(.missedCall(missed))
            case .badge, .removeMissedNotifications: break
            }
        }
        clipboard.onNotice = { [weak self] notice in self?.log.append(.clipboard(notice)) }
        let record = workspace.pairedDevice
        sms.setPair(record?.pairId, phoneDeviceId: record?.peerDeviceId, capability: record?.peerCapability)
        calls.setPair(record?.pairId, phoneDeviceId: record?.peerDeviceId, capability: record?.peerCapability)
        callLog.setPair(record?.pairId, capability: record?.peerCapability)
    }

    /// Starts the manager on the stored pair (the `last_host` fast path to the forwarded address).
    func start() {
        let phone = workspace.activePhone()
        events = Task { [manager, weak self] in
            await manager.start(phone: phone, relayEnabled: false)
            for await event in manager.events {
                await self?.handle(event)
            }
        }
    }

    func stop() async {
        events?.cancel()
        await manager.stop()
    }

    /// Waits until a session is up; `nil` when none came within `timeout`.
    func connected(within timeout: Duration) async -> ConnectionRoute? {
        if let session { return session.route }
        return await log.wait(from: 0, timeout: timeout) { event in
            if case .connected(let route) = event { return route }
            return nil
        }?.value
    }

    private func handle(_ event: LinkEvent) async {
        switch event {
        case .status(let status):
            if verbose { DevConsole.line("link: \(status.status)") }
        case .connected(let session, let details):
            connected(session, details: details)
        case .capabilityUpdated(let capability):
            peerCapability = capability
            workspace.updatePair { $0.peerCapability = capability }
            clipboard.phoneCapabilityUpdated(capability.features.clipboard)
            sms.capabilityUpdated(capability)
            calls.capabilityUpdated(capability)
            callLog.capabilityUpdated(capability)
            if verbose { DevConsole.line("capability/update from the phone: \(Self.summary(capability))") }
        case .disconnected:
            session = nil
            workspace.updatePair { $0.lastSeenAt = HLUUID.currentTimeMs() }
            clipboard.phoneDisconnected()
            sms.disconnected()
            calls.disconnected()
            callLog.disconnected()
            log.append(.disconnected)
        case .message(let envelope):
            route(envelope)
        case .pairRemoved(let removal):
            DevConsole.line("the phone removed the pair (\(removal)); the stored pair is deleted")
            if let pairId = workspace.pairedDevice?.pairId {
                try? workspace.secrets.delete(account: pairId)
                try? workspace.store.remove(pairId: pairId)
            }
        case .relayPairRegistered, .relayPairMissing, .relayDeviceRevoked:
            break
        }
    }

    private func connected(_ session: ControlSession, details: LinkDetails) {
        self.session = session
        peerCapability = details.peerCapability
        workspace.updatePair { record in
            if let host = details.host, let port = details.port {
                record.lastHost = host
                record.lastPort = port
            }
            record.lastSeenAt = HLUUID.currentTimeMs()
            record.peerCapability = details.peerCapability
        }
        if let record = workspace.pairedDevice {
            clipboard.phoneConnected(peer: SessionClipboardPeer(session: session), deviceId: record.peerDeviceId,
                                     name: record.peerName, feature: details.peerCapability.features.clipboard)
        }
        sms.connected(peer: SessionSmsPeer(session: session), capability: details.peerCapability)
        let callPeer = SessionCallPeer(session: session)
        calls.connected(peer: callPeer, capability: details.peerCapability)
        callLog.connected(peer: callPeer, capability: details.peerCapability)
        if verbose {
            DevConsole.line("connected (\(details.route)) to \(details.host ?? "?"):\(details.port.map(String.init) ?? "?"); "
                + "phone capability: \(Self.summary(details.peerCapability))")
        }
        log.append(.connected(details.route))
    }

    /// The phone's messages go to the engines, as in `AppModel`; `listen` also prints them.
    private func route(_ envelope: IncomingEnvelope) {
        record(envelope)
        switch envelope.type {
        case .clipboard: clipboard.receive(envelope)
        case .sms: sms.receive(envelope)
        case .callEvent:
            calls.receive(envelope)
            callLog.receive(envelope)
        default: break
        }
    }

    static func summary(_ capability: CapabilityData) -> String {
        let features = capability.features
        var parts = ["\(capability.platform.rawValue) \(capability.osVersion), app \(capability.appVersion)"]
        parts.append("clipboard \(features.clipboard?.enabled == true ? "on" : "off")")
        parts.append("sms \(features.sms?.enabled == true ? "on" : "off") can_send=\(features.sms?.canSend ?? false)")
        parts.append("call \(features.call?.enabled == true ? "on" : "off") caller_id=\(features.call?.callerId ?? false)")
        if let missing = capability.permissionsMissing, !missing.isEmpty { parts.append("missing \(missing)") }
        return parts.joined(separator: ", ")
    }
}
