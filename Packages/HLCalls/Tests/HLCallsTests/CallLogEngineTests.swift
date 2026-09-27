import Foundation
import HLAppCore
import HLProtocol
import Testing
@testable import HLCalls

/// CALL-04 steps 1–12 with a scripted phone: sync pages, the errors E1–E7, log_new and the missed-call notifications.
@Suite("Call log engine")
@MainActor
struct CallLogEngineTests {
    let pairId = CallLogFixtures.pairId

    func engine(_ store: CallLogStore) -> CallLogEngine {
        let engine = CallLogEngine(store: store, now: { 1000 })
        engine.requestTimeout = .milliseconds(200)
        engine.providerRetryDelay = .milliseconds(50)
        return engine
    }

    @Test("First sync: no cursor, limit 200, pages until has_more is false, cursor of each page kept; then done")
    func firstSync() async throws {
        let store = try CallLogFixtures.store()
        let engine = engine(store)
        let log = CallLogEventLog(engine)
        let peer = ScriptedCallPeer([
            .page(CallLogFixtures.page([CallLogFixtures.entry(1, .missed)], cursor: "c1", hasMore: true)),
            .page(CallLogFixtures.page([CallLogFixtures.entry(2, .incoming)], cursor: "c2")),
        ])
        engine.setPair(pairId, capability: CallLogFixtures.capability())
        engine.connected(peer: peer, capability: CallLogFixtures.capability())
        #expect(await eventually { engine.status == .done })
        #expect(peer.sent == [CallLogSyncRequest(cursor: nil), CallLogSyncRequest(cursor: "c1")])
        #expect(try await store.cursor(pairId: pairId) == "c2")
        #expect(log.missed.isEmpty && log.lastBadge == 0) // entries from log_sync notify nothing (no flood)
        let next = ScriptedCallPeer([.page(CallLogFixtures.page([CallLogFixtures.entry(3, .missed)], cursor: "c3"))])
        engine.disconnected()
        engine.connected(peer: next, capability: CallLogFixtures.capability())
        #expect(await eventually { next.sent == [CallLogSyncRequest(cursor: "c2")] && engine.status == .done })
        #expect(await eventually { log.lastBadge == 1 })
    }

    @Test("Without the phone's call log nothing syncs (E2); PERMISSION_MISSING stops the sync")
    func permission() async throws {
        let engine = engine(try CallLogFixtures.store())
        let silent = ScriptedCallPeer([])
        engine.setPair(pairId, capability: nil)
        engine.connected(peer: silent, capability: CallLogFixtures.capability(callerId: false))
        #expect(engine.status == .permissionMissing && silent.sent.isEmpty)
        let missing = CallLogFixtures.capability(missing: ["READ_CALL_LOG"])
        engine.capabilityUpdated(missing)
        #expect(!engine.callLogAvailable)
        let refused = ScriptedCallPeer([.refused(.permissionMissing)])
        engine.connected(peer: refused, capability: CallLogFixtures.capability())
        #expect(await eventually { engine.status == .permissionMissing && refused.sent.count == 1 })
    }

    @Test("A provider error is retried once (E6); no ack stops until the next connection (E4)")
    func errors() async throws {
        let store = try CallLogFixtures.store()
        let engine = engine(store)
        let retried = ScriptedCallPeer([.refused(.internal), .page(CallLogFixtures.page([], cursor: "c1"))])
        engine.setPair(pairId, capability: nil)
        engine.connected(peer: retried, capability: CallLogFixtures.capability())
        #expect(await eventually { engine.status == .done && retried.sent.count == 2 })
        let twice = ScriptedCallPeer([.refused(.internal), .refused(.internal)])
        engine.disconnected()
        engine.connected(peer: twice, capability: CallLogFixtures.capability())
        #expect(await eventually { engine.status == .interrupted && twice.sent.count == 2 })
        let silent = ScriptedCallPeer([])
        engine.disconnected()
        engine.connected(peer: silent, capability: CallLogFixtures.capability())
        #expect(await eventually { engine.status == .interrupted && silent.sent.count == 1 })
        #expect(try await store.cursor(pairId: pairId) == "c1")
    }

    @Test("log_new: a new missed call is notified once with the SIM label; not with notifications off")
    func logNew() async throws {
        let engine = engine(try CallLogFixtures.store())
        let log = CallLogEventLog(engine)
        engine.setPair(pairId, capability: CallLogFixtures.capability())
        let entry = CallLogFixtures.entry(5120, .missed, name: "Nguyễn Văn A", subId: 2)
        engine.receive(CallLogFixtures.logNew(entry, callId: "0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90"))
        #expect(await eventually { log.missed.count == 1 })
        #expect(log.missed.first == MissedCall(pairId: pairId, entryId: 5120, callId: "0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90",
                                               number: "+84900000123", caller: .name("Nguyễn Văn A"), ts: 5_120_000,
                                               subId: 2, simLabel: "SIM 2"))
        engine.receive(CallLogFixtures.logNew(entry))
        engine.receive(CallLogFixtures.logNew(CallLogFixtures.entry(5121, .incoming)))
        #expect(await eventually { log.lastBadge == 1 && log.events.count >= 3 })
        #expect(log.missed.count == 1)
        engine.notifyEnabled = { false }
        engine.receive(CallLogFixtures.logNew(CallLogFixtures.entry(5122, .missed)))
        #expect(await eventually { log.lastBadge == 2 })
        #expect(log.missed.count == 1)
    }

    @Test("Opening the list and tapping a notification see missed calls and remove their notifications")
    func seen() async throws {
        let engine = engine(try CallLogFixtures.store())
        let log = CallLogEventLog(engine)
        engine.setPair(pairId, capability: CallLogFixtures.capability())
        engine.receive(CallLogFixtures.logNew(CallLogFixtures.entry(1, .missed)))
        engine.receive(CallLogFixtures.logNew(CallLogFixtures.entry(2, .missed)))
        #expect(await eventually { log.lastBadge == 2 })
        await engine.markSeen(entryId: 1)
        #expect(log.lastBadge == 1 && log.events.contains(.removeMissedNotifications(pairId: pairId, entryId: 1)))
        await engine.markAllSeen()
        #expect(log.lastBadge == 0 && log.events.contains(.removeMissedNotifications(pairId: pairId, entryId: nil)))
    }

    @Test("The list model follows the database and sees the missed calls while it is on screen")
    func model() async throws {
        let store = try CallLogFixtures.store()
        let engine = engine(store)
        let model = CallsModel(engine: engine, store: store)
        engine.onEvent = { model.apply($0) }
        engine.setPair(pairId, capability: CallLogFixtures.capability())
        model.setPair(pairId)
        engine.receive(CallLogFixtures.logNew(CallLogFixtures.entry(1, .missed)))
        #expect(await eventually { model.entries.map(\.entryId) == [1] && model.unseenMissed == 1 })
        model.setVisible(true)
        #expect(await eventually { model.unseenMissed == 0 && model.entries.first?.seen == true })
        engine.receive(CallLogFixtures.logNew(CallLogFixtures.entry(2, .missed)))
        #expect(await eventually { model.entries.count == 2 && model.unseenMissed == 0 })
    }
}
