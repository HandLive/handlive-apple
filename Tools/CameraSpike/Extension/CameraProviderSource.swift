import CoreMediaIO
import Foundation
import os

/// The provider: one device, "HandLive Camera Spike". Logs every client that connects, with its signing ID, because
/// the sink stream only admits the host app (CAM-01 API 3 rule 3).
final class CameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CameraDeviceSource!
    private let log = Logger.spike("provider")

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = CameraDeviceSource()
        do {
            try provider.addDevice(deviceSource.device)
            log.info("device added: \(SpikeIdentifiers.cameraUID, privacy: .public)")
        } catch {
            log.fault("addDevice failed: \(String(describing: error), privacy: .public)")
            fatalError("addDevice failed: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {
        log.info("client connected pid=\(client.pid) signingID=\(client.signingID ?? "-", privacy: .public)")
    }

    func disconnect(from client: CMIOExtensionClient) {
        log.info("client disconnected pid=\(client.pid)")
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { result.manufacturer = "HandLive" }
        return result
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
