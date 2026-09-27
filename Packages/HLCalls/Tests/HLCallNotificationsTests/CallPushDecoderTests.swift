import Foundation
import HLAppCore
import HLCrypto
import HLLocalization
import HLProtocol
import HLSMSNotifications
import Testing
import UserNotifications
@testable import HLCallNotifications

/// CONN-04 step 9b with the call pushes of `shared/test-vectors/push-envelope.json`: ringing with and without the
/// number, missed from the call log with and without a matching call, missed without the call log (flow A).
@Suite("Call pushes in the Notification Service Extension")
struct CallPushDecoderTests {
    struct Vector {
        let name: String
        let payload: [AnyHashable: Any]
        let prk: Data
        let ts: Int64
        let type: String
    }

    static func vectors() throws -> [Vector] {
        let url = CallTestFiles.vectorsDirectory.appendingPathComponent("push-envelope.json")
        let file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let all = try #require(file["vectors"] as? [[String: Any]])
        var prks: [String: Data] = [:]
        for key in all where key["kind"] as? String == "key" {
            let hex = try #require(key["prk"] as? String)
            let pairId = try #require(key["pair_id"] as? String)
            prks[pairId] = Data(stride(from: 0, to: hex.count, by: 2).map {
                UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)...].prefix(2), radix: 16) ?? 0
            })
        }
        return try all.filter { $0["kind"] as? String == "envelope" }.map { vector in
            let text = try #require(vector["apns_payload"] as? String)
            let payload = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [AnyHashable: Any])
            let ts = (vector["ts"] as? NSNumber)?.int64Value ?? Int64(vector["ts"] as? String ?? "") ?? 0
            let pairId = try #require(vector["pair_id"] as? String)
            let prk = try #require(prks[pairId])
            return Vector(name: vector["name"] as? String ?? "?", payload: payload, prk: prk, ts: ts,
                          type: vector["type"] as? String ?? "")
        }
    }

    static func decoded(_ name: String) throws -> CallPushDecoder.Decoded {
        let vector = try #require(try vectors().first { $0.name == name })
        return try #require(CallPushDecoder.decode(userInfo: vector.payload, nowMs: vector.ts + 1000) { _ in vector.prk })
    }

    @Test("Every call vector decodes; SMS pushes are not calls")
    func everyVector() throws {
        let vectors = try Self.vectors()
        let calls = vectors.filter { $0.type == "call_event" }
        #expect(calls.count == 5)
        for vector in calls {
            #expect(CallPushDecoder.decode(userInfo: vector.payload, nowMs: vector.ts + 1000) { _ in vector.prk } != nil,
                    "\(vector.name)")
        }
        for vector in vectors where vector.type == "sms" {
            #expect(CallPushDecoder.decode(userInfo: vector.payload, nowMs: vector.ts + 1000) { _ in vector.prk } == nil)
        }
    }

    @Test("Ringing: the state with the iPhone's controls, the name and the SIM label; without the number too")
    func ringing() throws {
        guard case .incoming(let state) = try Self.decoded("pair 2 / call_event/state ringing").content else {
            Issue.record("not an incoming call")
            return
        }
        #expect(state.displayName == "Nguyễn Văn A" && state.simLabel == "SIM 1" && !state.controls.answer)
        let content = CallNotificationBuilder.incoming(state, pairId: "9a8b7c6d-5e4f-4a3b-9c2d-1e0f2a3b4c5d",
                                                       platform: .mobile, level: .timeSensitive,
                                                       nowMs: state.startedAt + 1000)
        #expect(content.title == "Nguyễn Văn A" && content.body == L10n.Call.incomingBodySim(simLabel: "SIM 1"))
        guard case .incoming(let unknown) = try Self.decoded("pair 2 / call_event/state ringing without the caller's number")
            .content else {
            Issue.record("not an incoming call")
            return
        }
        #expect(CallerIdentity(state: unknown) == .unknownCaller && unknown.simLabel == nil)
    }

    @Test("Rebuilt from the push: p and hl stay next to the call's keys; a late push has no button and keeps its level")
    func rebuilt() throws {
        let vector = try #require(try Self.vectors().first { $0.name == "pair 2 / call_event/state ringing" })
        let decoded = try Self.decoded(vector.name)
        guard case .incoming(let state) = decoded.content else {
            Issue.record("not an incoming call")
            return
        }
        let push = UNMutableNotificationContent()
        push.userInfo = vector.payload
        push.interruptionLevel = .timeSensitive
        let onTime = CallNotificationBuilder.incoming(state, pairId: decoded.pairId, platform: .mobile,
                                                      level: .timeSensitive, nowMs: state.startedAt + 1000)
            .makeContent(base: push)
        #expect(onTime.userInfo["p"] as? String == decoded.pairId && onTime.userInfo["hl"] is String)
        #expect(CallNotificationInfo(onTime.userInfo)
            == .incoming(pairId: decoded.pairId, callId: state.callId, startedAt: state.startedAt))
        #expect(onTime.categoryIdentifier == "HL_CALL_INCOMING" && onTime.threadIdentifier == "calls")
        let late = CallNotificationBuilder.incoming(state, pairId: decoded.pairId, platform: .mobile,
                                                    level: .timeSensitive, nowMs: state.startedAt + 61_000)
            .makeContent(base: push)
        #expect(late.categoryIdentifier.isEmpty && late.interruptionLevel == .timeSensitive)
        #expect(late.body == L10n.Call.incomingLate(time: CallNames.time(state.startedAt)))
    }

    @Test("Missed: from log_new with and without a matching call, and from the state without the call log")
    func missed() throws {
        let fromLog = try Self.decoded("pair 2 / call_event/log_new missed call")
        #expect(fromLog.content == .missed(MissedCall(
            pairId: "9a8b7c6d-5e4f-4a3b-9c2d-1e0f2a3b4c5d", entryId: 5120, callId: "0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90",
            number: "+84900000123", caller: .name("Nguyễn Văn A"), ts: 1_727_150_400_123, subId: 1, simLabel: nil)))
        guard case .missed(let unmatched) = try Self.decoded("pair 2 / call_event/log_new missed call without a matching call")
            .content else {
            Issue.record("not a missed call")
            return
        }
        #expect(unmatched.entryId == 5121 && unmatched.callId == nil && unmatched.caller == .number("+84900000789"))
        guard case .missed(let flowA) = try Self.decoded("pair 2 / call_event/state missed without the call log").content
        else {
            Issue.record("not a missed call")
            return
        }
        #expect(flowA.entryId == nil && flowA.caller == .unknownCaller && flowA.number == nil)
        #expect(CallNotificationBuilder.missed(flowA, canMessage: true, pushed: true).categoryIdentifier == nil)
    }

    @Test("Locked (no key), another key, more than 24 h late or not a push: the generic content stays")
    func generic() throws {
        let vector = try #require(try Self.vectors().first { $0.type == "call_event" })
        #expect(CallPushDecoder.decode(userInfo: vector.payload, nowMs: vector.ts) { _ in nil } == nil)
        #expect(CallPushDecoder.decode(userInfo: vector.payload, nowMs: vector.ts) { _ in Data(repeating: 1, count: 32) }
                == nil)
        #expect(CallPushDecoder.decode(userInfo: vector.payload, nowMs: vector.ts + PushEnvelope.maxAgeMs + 1) { _ in
            vector.prk
        } == nil)
        #expect(CallPushDecoder.decode(userInfo: ["aps": [:]], nowMs: 0) { _ in vector.prk } == nil)
    }

    @Test("Removal: a call's incoming notifications, the stale ones on opening the app, a pair's missed calls")
    func filters() {
        let pairId = "9a8b7c6d-5e4f-4a3b-9c2d-1e0f2a3b4c5d"
        let incoming = CallNotificationInfo.incoming(pairId: pairId, callId: "c1", startedAt: 1000)
        let newer = CallNotificationInfo.incoming(pairId: pairId, callId: "c2", startedAt: 90_000)
        let missed = CallNotificationInfo.missed(pairId: pairId, entryId: 7, callId: nil, number: nil, subId: nil)
        let delivered = [
            DeliveredNotification(identifier: "a", userInfo: incoming.userInfo),
            DeliveredNotification(identifier: "b", userInfo: newer.userInfo),
            DeliveredNotification(identifier: "c", userInfo: missed.userInfo),
            DeliveredNotification(identifier: "d", userInfo: ["p": pairId, "hl": "generic"]),
        ]
        #expect(CallNotificationFilter.incomingIdentifiers(in: delivered, callId: "c1") == ["a"])
        let stale = CallNotificationFilter.staleIncomingIdentifiers(in: delivered, nowMs: 100_000) { _ in
            CallStateData(callId: "c3", direction: .incoming, state: .ringing, number: nil, displayName: nil,
                          presentation: .unknown, startedAt: 2000, controls: .none)
        }
        #expect(stale == ["a", "d"])
        #expect(CallNotificationFilter.missedIdentifiers(in: delivered, pairId: pairId) == ["c"])
        #expect(CallNotificationFilter.missedIdentifiers(in: delivered, pairId: pairId, entryId: 8).isEmpty)
    }
}
