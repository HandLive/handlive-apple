import Foundation
import HLCrypto
import HLProtocol
import HLTransport
@testable import HLAppCore

/// The phone as the engine sees it: records what is sent and answers pushes with scripted acks.
final class FakeClipboardPeer: ClipboardPeer, @unchecked Sendable {
    enum Answer {
        case applied, ignored(ClipboardAckData.Reason), error(ErrorCode), timeout
    }

    private let lock = NSLock()
    private var answers: [Answer] = []
    private var storedPushes: [ClipboardPushData] = []
    private var storedChunks: [ClipboardChunkPlaintext] = []
    private var storedCancels: [ClipboardCancelData] = []
    private var storedConflicts: [ClipboardConflictData] = []
    private var storedReplies: [(requestId: String, ack: Ack)] = []
    /// Delay per chunk, to cancel a transfer midway.
    var chunkDelay: Duration = .zero

    func answer(_ next: Answer...) {
        lock.lock()
        answers += next
        lock.unlock()
    }

    var pushes: [ClipboardPushData] { locked { storedPushes } }
    var chunks: [ClipboardChunkPlaintext] { locked { storedChunks } }
    var cancels: [ClipboardCancelData] { locked { storedCancels } }
    var conflicts: [ClipboardConflictData] { locked { storedConflicts } }
    var replies: [(requestId: String, ack: Ack)] { locked { storedReplies } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func sendPush(_ push: ClipboardPushData) async throws -> any AckWaiting {
        let answer: Answer = locked {
            storedPushes.append(push)
            return answers.isEmpty ? .applied : answers.removeFirst()
        }
        return ScriptedAck(clipId: push.clipId, transferId: push.transfer?.transferId, answer: answer)
    }

    func sendChunk(_ chunk: ClipboardChunkPlaintext) async throws {
        if chunkDelay > .zero { try await Task.sleep(for: chunkDelay) }
        locked { storedChunks.append(chunk) }
    }

    func sendCancel(_ cancel: ClipboardCancelData) async throws {
        locked { storedCancels.append(cancel) }
    }

    func sendConflict(_ conflict: ClipboardConflictData) async throws {
        locked { storedConflicts.append(conflict) }
    }

    func reply(to requestId: String, with ack: Ack) async throws {
        locked { storedReplies.append((requestId, ack)) }
    }
}

struct ScriptedAck: AckWaiting {
    let clipId: String
    let transferId: String?
    let answer: FakeClipboardPeer.Answer

    func response(timeout: Duration) async throws -> Ack {
        let re = HLUUID.v7()
        switch answer {
        case .applied:
            return .success(re: re, data: try HLJSON.convert(from: ClipboardAckData(clipId: clipId, status: .applied)))
        case .ignored(let reason):
            return .success(re: re, data: try HLJSON.convert(from: ClipboardAckData(clipId: clipId, status: .ignored,
                                                                                    reason: reason)))
        case .error(let code):
            let details = try HLJSON.convert(from: ClipboardAckData(clipId: clipId, status: .rejected, transferId: transferId))
            return .failure(re: re, error: AckError(code: code, message: "test", details: details))
        case .timeout:
            throw SessionError.timedOut
        }
    }
}

/// Engine, pasteboard, phone and a settable clock for one test.
@MainActor
final class ClipboardHarness {
    let pasteboard = FakePasteboard()
    let peer = FakeClipboardPeer()
    let settings: AppSettings
    var clock = Date(timeIntervalSince1970: 1_727_150_000)
    var readingAllowed = true
    private(set) var notices: [ClipboardNotice] = []
    private(set) var alerts: [ClipboardAlert] = []
    private(set) var progress: [ClipboardProgress.Direction: ClipboardProgress] = [:]
    private(set) var progressSeen = false
    var engine: ClipboardEngine!
    let platform: ClipboardPlatform
    private(set) var unsentBanner: [Bool] = []
    static let macId = "5b1f8c2e-9a4d-8e6f-a1b2-c3d4e5f60718"
    static let phoneId = "8c7d6e5f-4a3b-8c2d-9e1f-0a1b2c3d4e5f"

    init(connected: Bool = true, platform: ClipboardPlatform = .mac, feature: ClipboardFeature? = ClipboardFeature(
        enabled: true, autoSend: true, maxTextBytes: 1_048_576, maxImageBytes: 10_485_760,
        mimes: [ClipMime.text, ClipMime.png, ClipMime.jpeg])) {
        let name = "app.handlive.tests.\(UUID().uuidString)"
        settings = AppSettings(defaults: UserDefaults(suiteName: name)!)
        self.platform = platform
        readingAllowed = platform == .mac
        engine = makeEngine()
        if connected { connect(feature: feature) }
    }

    func makeEngine() -> ClipboardEngine {
        // Weak: timers of the engine (auto-clear, idle transfer) may fire after the test ended.
        let engine = ClipboardEngine(access: pasteboard, settings: settings, deviceId: Self.macId,
                                     deviceName: "MacBook của Lan", platform: platform,
                                     readingAllowed: { [weak self] in self?.readingAllowed ?? false },
                                     now: { [weak self] in self?.clock ?? Date() },
                                     temporaryDirectory: FileManager.default.temporaryDirectory
                                         .appendingPathComponent("handlive-clip-tests-\(UUID().uuidString)"))
        engine.onNotice = { [weak self] in self?.notices.append($0) }
        engine.onAlert = { [weak self] in self?.alerts.append($0) }
        engine.onUnsentLocalContent = { [weak self] in self?.unsentBanner.append($0) }
        engine.onProgress = { [weak self] direction, value in
            self?.progress[direction] = value
            if value != nil { self?.progressSeen = true }
        }
        return engine
    }

    func connect(feature: ClipboardFeature? = ClipboardFeature(enabled: true, autoSend: true, maxTextBytes: 1_048_576,
                                                                maxImageBytes: 10_485_760,
                                                                mimes: [ClipMime.text, ClipMime.png, ClipMime.jpeg])) {
        engine.phoneConnected(peer: peer, deviceId: Self.phoneId, name: "Pixel của Lan", feature: feature)
    }

    func advance(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
    }

    /// Waits until `condition` holds, up to two seconds.
    func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Whether a push is in flight. A text clip's push starts synchronously in `poll()`, `sendAnyway()`,
    /// `sendClipboardNow()`, `sendPasted(_:)` and `phoneConnected`, and stays in flight until its ack was handled, so
    /// reading this right after the call tells whether anything was sent, with no waiting.
    var sending: Bool { engine.sending != nil }

    /// Waits until the push in flight, if any, is over, up to two seconds: its ack was handled (acknowledged,
    /// suspended, told), or it ended without one (no ack in time, an error, the session gone). It says nothing about
    /// which: the test checks that itself.
    func pushSettled() async -> Bool {
        await until { engine.sending == nil }
    }

    /// A push from the phone, as the session delivers it.
    func receive(_ push: ClipboardPushData) -> String {
        let id = HLUUID.v7()
        let payload = Payload(op: ClipboardOp.push.rawValue, data: (try? HLJSON.convert(from: push)) ?? .emptyObject)
        engine.receive(IncomingEnvelope(id: id, type: .clipboard, ts: 0, body: .json(payload)))
        return id
    }

    func receive<Body: Encodable>(_ op: ClipboardOp, _ data: Body) {
        let payload = Payload(op: op.rawValue, data: (try? HLJSON.convert(from: data)) ?? .emptyObject)
        engine.receive(IncomingEnvelope(id: HLUUID.v7(), type: .clipboard, ts: 0, body: .json(payload)))
    }

    func receiveChunk(_ chunk: ClipboardChunkPlaintext) {
        engine.receive(IncomingEnvelope(id: HLUUID.v7(), type: .clipboard, ts: 0,
                                        body: .binary((try? chunk.encoded()) ?? Data())))
    }

    /// The data of the reply to `requestId`, once it was sent.
    func reply(to requestId: String) async -> Ack? {
        _ = await until { peer.replies.contains { $0.requestId == requestId } }
        return peer.replies.first { $0.requestId == requestId }?.ack
    }

    /// A phone that takes the HTML form of a text clip.
    static let htmlFeature = ClipboardFeature(enabled: true, autoSend: true, maxTextBytes: 1_048_576,
                                              maxImageBytes: 10_485_760,
                                              mimes: [ClipMime.text, ClipMime.html, ClipMime.png, ClipMime.jpeg])

    static func textPush(_ text: String, clipId: String = HLUUID.v7(), originTs: Int64 = 1_727_150_000_000,
                         sensitive: Bool = false, html: String? = nil) -> ClipboardPushData {
        ClipboardPushData(clipId: clipId, kind: .text, mime: ClipMime.text, text: text, html: html, sensitive: sensitive,
                          originTs: originTs, source: .auto, originDeviceId: phoneId)
    }
}
