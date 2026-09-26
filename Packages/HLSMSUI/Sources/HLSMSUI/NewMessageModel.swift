import Foundation
import GRDB
import HLProtocol
import HLSMS

/// "New Message" (SMS-04 field 1, steps 1–3 and 11): a number, the text and the SIM; once the phone's copy of the
/// message arrives, its conversation opens in place of the compose screen.
@MainActor
public final class NewMessageModel: ObservableObject {
    @Published public var recipient = ""
    @Published public var draft = "" {
        didSet { counter = SmsDisplay.counter(for: draft) }
    }
    @Published public private(set) var counter = SmsDisplay.counter(for: "")
    @Published public var subId: Int32?
    /// The recipient field failed the basic check (reported at the field, step 2).
    @Published public private(set) var recipientInvalid = false
    /// Messages sent from this screen that the phone has not echoed yet.
    @Published public private(set) var sent: [SmsOutboxEntry] = []

    let engine: SmsEngine
    let store: SmsStore
    let pairId: String
    /// The conversation the phone created for the first message (step 11).
    public var onThreadCreated: (Int64) -> Void = { _ in }
    var watch: Task<Void, Never>?

    public init(engine: SmsEngine, store: SmsStore, pairId: String) {
        self.engine = engine
        self.store = store
        self.pairId = pairId
        subId = engine.defaultSubId
    }

    public var sims: [SimInfo] { engine.sims.count > 1 ? engine.sims : [] }

    public var canSend: Bool {
        SmsEngine.validRecipient(recipient) != nil && SmsEngine.validText(draft) != nil && engine.canSend
    }

    public func send() async {
        guard let address = SmsEngine.validRecipient(recipient) else {
            recipientInvalid = true
            return
        }
        recipientInvalid = false
        let text = draft
        draft = ""
        guard let localId = try? await engine.send(text: text, to: address, threadId: nil, subId: subId) else {
            draft = text
            return
        }
        watchEcho(of: localId)
    }

    /// Step 11: the thread of the real message carrying this `local_id`.
    private func watchEcho(of localId: String) {
        watch?.cancel()
        let pairId = pairId
        let pool = store.database.pool
        let echo = ValueObservation.tracking { db -> (Int64?, [SmsOutboxEntry]) in
            (try Int64.fetchOne(db, sql: "SELECT thread_id FROM sms_message WHERE pair_id = ? AND local_id = ?",
                                arguments: [pairId, localId]),
             try SmsStore.placeholders(db, pairId: pairId, threadId: nil))
        }
        watch = Task { [weak self] in
            do {
                for try await (threadId, pending) in echo.values(in: pool) {
                    self?.sent = pending
                    if let threadId {
                        self?.onThreadCreated(threadId)
                        return
                    }
                }
            } catch {
                return
            }
        }
    }
}
