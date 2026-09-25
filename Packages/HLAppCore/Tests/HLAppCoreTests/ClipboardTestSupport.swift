import Foundation
import HLCrypto
import HLProtocol
import HLTransport
@testable import HLAppCore

/// An in-memory pasteboard: one item with typed values, a `changeCount`, and counters of content reads.
@MainActor
final class FakePasteboard: ClipboardAccess {
    private(set) var changeCount = 1
    private(set) var types: [String] = []
    private var values: [String: Data] = [:]
    private(set) var contentReads = 0
    struct Write: Equatable {
        let content: ClipContent
        let clipId: String
        let sensitive: Bool
    }

    private(set) var writes: [Write] = []
    var failWrites = false

    /// The user copies in another app.
    func copy(_ items: [(String, Data)]) {
        types = items.map(\.0)
        values = Dictionary(uniqueKeysWithValues: items)
        changeCount += 1
    }

    func copy(text: String, extraTypes: [String] = []) {
        copy([(PasteboardTypeID.text, Data(text.utf8))] + extraTypes.map { ($0, Data()) })
    }

    func firstItemTypes() -> [String]? {
        contentReads += 1
        return types.isEmpty ? nil : types
    }

    func string(forType type: String) -> String? {
        contentReads += 1
        return values[type].flatMap { String(data: $0, encoding: .utf8) }
    }

    func data(forType type: String) -> Data? {
        contentReads += 1
        return values[type]
    }

    func write(_ content: ClipContent, clipId: String, sensitive: Bool) -> Int? {
        guard !failWrites else { return nil }
        writes.append(Write(content: content, clipId: clipId, sensitive: sensitive))
        var items: [(String, Data)]
        switch content {
        case .text(let text): items = [(PasteboardTypeID.text, Data(text.utf8))]
        case .image(let image): items = [(image.mime == ClipMime.png ? PasteboardTypeID.png : PasteboardTypeID.jpeg,
                                          image.data)]
        }
        items.append((PasteboardTypeID.clipId, Data(clipId.utf8)))
        if sensitive { items.append((PasteboardTypeID.concealed, Data())) }
        copy(items)
        return changeCount
    }

    func clear() -> Int {
        types = []
        values = [:]
        changeCount += 1
        return changeCount
    }
}

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
    static let macId = "5b1f8c2e-9a4d-8e6f-a1b2-c3d4e5f60718"
    static let phoneId = "8c7d6e5f-4a3b-8c2d-9e1f-0a1b2c3d4e5f"

    init(connected: Bool = true, feature: ClipboardFeature? = ClipboardFeature(
        enabled: true, autoSend: true, maxTextBytes: 1_048_576, maxImageBytes: 10_485_760,
        mimes: [ClipMime.text, ClipMime.png, ClipMime.jpeg])) {
        let name = "app.handlive.tests.\(UUID().uuidString)"
        settings = AppSettings(defaults: UserDefaults(suiteName: name)!)
        engine = makeEngine()
        if connected { connect(feature: feature) }
    }

    func makeEngine() -> ClipboardEngine {
        let engine = ClipboardEngine(access: pasteboard, settings: settings, deviceId: Self.macId,
                                     deviceName: "MacBook của Lan", readingAllowed: { [unowned self] in readingAllowed },
                                     now: { [unowned self] in clock },
                                     temporaryDirectory: FileManager.default.temporaryDirectory
                                         .appendingPathComponent("handlive-clip-tests-\(UUID().uuidString)"))
        engine.onNotice = { [unowned self] in notices.append($0) }
        engine.onAlert = { [unowned self] in alerts.append($0) }
        engine.onProgress = { [unowned self] direction, value in
            progress[direction] = value
            if value != nil { progressSeen = true }
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

    static func textPush(_ text: String, clipId: String = HLUUID.v7(), originTs: Int64 = 1_727_150_000_000,
                         sensitive: Bool = false) -> ClipboardPushData {
        ClipboardPushData(clipId: clipId, kind: .text, mime: ClipMime.text, text: text, sensitive: sensitive,
                          originTs: originTs, source: .auto, originDeviceId: phoneId)
    }
}

extension Ack {
    var clipboardData: ClipboardAckData? {
        (ok ? data : error?.details).flatMap { try? HLJSON.convert($0, to: ClipboardAckData.self) }
    }
}
