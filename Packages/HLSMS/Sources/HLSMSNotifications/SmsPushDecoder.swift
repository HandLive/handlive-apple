import Foundation
import HLCrypto
import HLProtocol

/// What the Notification Service Extension reads from an APNs alert (CONN-04 step 9b): `p` and `hl`, the pair's `PRK`
/// from the shared Keychain, `K_push`, the 24-hour limit and an `sms/new` inside. Anything else keeps the generic
/// content the relay sent (E5: locked device, missing key, undecryptable or unknown content; E7: too old).
public enum SmsPushDecoder {
    public struct Decoded: Equatable, Sendable {
        public let pairId: String
        /// Envelope `id`, for de-duplication (E7).
        public let envelopeId: String
        public let new: SmsNewData
    }

    /// `prk` returns the pair's `PRK`, or `nil` when the Keychain refuses (the device is locked, C3).
    public static func decode(userInfo: [AnyHashable: Any], nowMs: Int64,
                              prk: (String) -> Data?) -> Decoded? {
        guard let fields = PushAlertFields(userInfo: userInfo), fields.envelope.type == .sms,
              let key = prk(fields.pairId),
              let plaintext = try? PushEnvelope.open(fields.envelope, prk: key, nowMs: nowMs),
              let payload = try? Payload.parse(plaintext), payload.op == SmsOp.new.rawValue,
              let new = try? payload.decodeData(as: SmsNewData.self)
        else { return nil }
        return Decoded(pairId: fields.pairId, envelopeId: fields.envelope.id, new: new)
    }
}

/// Envelope ids the extension already showed (E7), kept 24 hours in a small file of the App Group container; at most
/// 500 ids. The extension is short-lived, so it reads and writes the file each time.
public struct PushDeduplicator: Sendable {
    public static let capacity = 500
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Records `id`; `false` when it was already there (a repeated push).
    public func firstSighting(of id: String, nowMs: Int64) -> Bool {
        var seen = ((try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: Int64].self, from: $0) })
            ?? [:]
        seen = seen.filter { nowMs - $0.value <= PushEnvelope.maxAgeMs }
        guard seen[id] == nil else { return false }
        seen[id] = nowMs
        if seen.count > Self.capacity {
            for (old, _) in seen.sorted(by: { $0.value < $1.value }).prefix(seen.count - Self.capacity) { seen[old] = nil }
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(seen).write(to: fileURL, options: .atomic)
        return true
    }
}
