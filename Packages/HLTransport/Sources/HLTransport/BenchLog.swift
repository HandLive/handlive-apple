import Foundation
import os

/// `HLBENCH/1` event lines for the latency benchmarks (shared/tools/bench/README.md). Debug builds only; release
/// builds never emit them. Values never contain content, names or addresses (QC2, 0.6.5).
public enum BenchLog {
    public enum Role: String, Sendable {
        case macos, ios
    }

    /// `dev` and `role` of the lines.
    struct Identity: Equatable {
        var device = "00000000"
        var role = Role.macos
    }

    private static let identity = OSAllocatedUnfairLock(initialState: Identity())

    /// Sets the `dev` (first 8 hex digits of `device_id`) and `role` of every later line.
    public static func configure(deviceId: String, role: Role) {
        let prefix = String(deviceId.replacingOccurrences(of: "-", with: "").prefix(8))
        identity.withLock { $0 = Identity(device: prefix, role: role) }
    }

    /// Logs one event in debug builds: `BenchLog.event("state", ["from": "Discovering", "to": "Connected"])`.
    public static func event(_ name: String, _ fields: KeyValuePairs<String, String> = [:]) {
        event(name, fields: fields.map { ($0.key, $0.value) })
    }

    /// Same, with fields built at run time (optional fields such as `code` go last).
    public static func event(_ name: String, fields: [(String, String)]) {
        #if DEBUG
        let current = identity.withLock { $0 }
        let text = line(wallMs: Date().timeIntervalSince1970 * 1000, monoNs: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW),
                        identity: current, event: name, fields: fields)
        Logger(subsystem: current.role == .macos ? "app.handlive.mac" : "app.handlive.ios", category: "bench")
            .info("\(text, privacy: .public)")
        #endif
    }

    /// `HLBENCH/1 wall=<ms> mono=<ns> dev=<id8> role=<role> ev=<event> [<key>=<value> …]`; spaces in values
    /// become `_` so a line always splits on spaces.
    static func line(wallMs: Double, monoNs: UInt64, identity: Identity, event: String,
                     fields: [(String, String)]) -> String {
        var parts = ["HLBENCH/1", "wall=\(String(format: "%.3f", wallMs))", "mono=\(monoNs)", "dev=\(identity.device)",
                     "role=\(identity.role.rawValue)", "ev=\(event)"]
        parts += fields.map { "\($0.0)=\($0.1.replacingOccurrences(of: " ", with: "_"))" }
        return parts.joined(separator: " ")
    }
}

extension ConnectionState {
    /// State name of the bench `state` event (0.11 names).
    var benchName: String {
        switch self {
        case .idle: "Idle"
        case .discovering: "Discovering"
        case .connectingLAN: "ConnectingLAN"
        case .connectingRelay: "ConnectingRelay"
        case .waitingPeer: "WaitingPeer"
        case .handshaking: "Handshaking"
        case .connected: "Connected"
        case .backoff: "Backoff"
        }
    }
}
