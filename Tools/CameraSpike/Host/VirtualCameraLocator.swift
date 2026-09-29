import CoreMediaIO
import Foundation

/// Finds the spike camera and its sink stream through the CoreMediaIO C API (CAM-01 API 3).
enum VirtualCameraLocator {
    struct Found {
        let deviceID: CMIOObjectID
        let sourceStreamID: CMIOStreamID?
        let sinkStreamID: CMIOStreamID
    }

    enum Failure: Error, CustomStringConvertible {
        case noDevice([String])
        case noSinkStream
        case status(String, OSStatus)

        var description: String {
            switch self {
            case .noDevice(let seen): "device \(SpikeIdentifiers.cameraUID) not found; devices seen: \(seen)"
            case .noSinkStream: "the device has no sink stream"
            case .status(let call, let status): "\(call) failed: \(status)"
            }
        }
    }

    /// Lets this process see screen-capture and virtual devices (CAM-01 step 7).
    static func allowVirtualDevices() {
        var address = address(CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    static func locate() throws -> Found {
        allowVirtualDevices()
        var seen: [String] = []
        for device in try objectIDs(of: CMIOObjectID(kCMIOObjectSystemObject),
                                    selector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices)) {
            let uid = (try? string(of: device, selector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID))) ?? "?"
            seen.append(uid)
            guard uid == SpikeIdentifiers.cameraUID else { continue }
            var source: CMIOStreamID?, sink: CMIOStreamID?
            for stream in try objectIDs(of: device, selector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams)) {
                // kCMIOStreamPropertyDirection: 0 = output (the sink we write), 1 = input (the source apps read).
                if try uint32(of: stream, selector: CMIOObjectPropertySelector(kCMIOStreamPropertyDirection)) == 0 {
                    sink = stream
                } else {
                    source = stream
                }
            }
            guard let sink else { throw Failure.noSinkStream }
            return Found(deviceID: device, sourceStreamID: source, sinkStreamID: sink)
        }
        throw Failure.noDevice(seen)
    }

    private static func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector,
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func objectIDs(of object: CMIOObjectID, selector: CMIOObjectPropertySelector) throws -> [CMIOObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        var status = CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard status == noErr else { throw Failure.status("GetPropertyDataSize", status) }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        status = CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &ids)
        guard status == noErr else { throw Failure.status("GetPropertyData", status) }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private static func uint32(of object: CMIOObjectID, selector: CMIOObjectPropertySelector) throws -> UInt32 {
        var address = address(selector)
        var value: UInt32 = 0, used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value)
        guard status == noErr else { throw Failure.status("GetPropertyData", status) }
        return value
    }

    private static func string(of object: CMIOObjectID, selector: CMIOObjectPropertySelector) throws -> String {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(object, &address, 0, nil,
                                               UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &value)
        guard status == noErr, let value else { throw Failure.status("GetPropertyData(string)", status) }
        return value.takeRetainedValue() as String
    }
}
