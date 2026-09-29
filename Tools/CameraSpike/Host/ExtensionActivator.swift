import Foundation
import SystemExtensions

/// Activates, inspects and deactivates the embedded Camera Extension with `OSSystemExtensionRequest` (CAM-01 API 1)
/// and logs every callback, so the owner can see which of E1–E4 happened and whether an update needs a restart (C11).
final class ExtensionActivator: NSObject, OSSystemExtensionRequestDelegate {
    private let log: SpikeEventLog
    private var pending: [ObjectIdentifier: String] = [:]

    init(log: SpikeEventLog) {
        self.log = log
    }

    func activate() { submit(.activationRequest(forExtensionWithIdentifier: SpikeIdentifiers.extensionBundleID,
                                                queue: .main), kind: "activate") }

    func deactivate() { submit(.deactivationRequest(forExtensionWithIdentifier: SpikeIdentifiers.extensionBundleID,
                                                    queue: .main), kind: "deactivate") }

    /// Properties of the installed versions (macOS 12+).
    func inspect() { submit(.propertiesRequest(forExtensionWithIdentifier: SpikeIdentifiers.extensionBundleID,
                                               queue: .main), kind: "properties") }

    private func submit(_ request: OSSystemExtensionRequest, kind: String) {
        request.delegate = self
        pending[ObjectIdentifier(request)] = kind
        log.record("extension_request", ["kind": kind, "app_in_applications": Bundle.main.bundlePath.hasPrefix("/Applications/")])
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func kind(of request: OSSystemExtensionRequest) -> String { pending[ObjectIdentifier(request)] ?? "?" }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        log.record("extension_replace", ["existing": "\(existing.bundleShortVersion) (\(existing.bundleVersion))",
                                         "new": "\(ext.bundleShortVersion) (\(ext.bundleVersion))"])
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        log.record("extension_needs_approval", ["kind": kind(of: request),
                                                "hint": "System Settings > General > Login Items & Extensions"])
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let text = result == .completed ? "completed" : result == .willCompleteAfterReboot ? "will_complete_after_reboot"
            : "raw_\(result.rawValue)"
        log.record("extension_finished", ["kind": kind(of: request), "result": text])
        pending[ObjectIdentifier(request)] = nil
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let nsError = error as NSError
        let name = OSSystemExtensionError.Code(rawValue: nsError.code).map { "\($0)" } ?? "unknown"
        log.record("extension_failed", ["kind": kind(of: request), "domain": nsError.domain, "code": nsError.code,
                                        "name": name, "message": nsError.localizedDescription])
        pending[ObjectIdentifier(request)] = nil
    }

    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let list = properties.map {
            ["version": "\($0.bundleShortVersion) (\($0.bundleVersion))", "enabled": $0.isEnabled,
             "awaiting_approval": $0.isAwaitingUserApproval, "uninstalling": $0.isUninstalling] as [String: Any]
        }
        log.record("extension_properties", ["installed": list,
                                            "embedded": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?"])
        pending[ObjectIdentifier(request)] = nil
    }
}
