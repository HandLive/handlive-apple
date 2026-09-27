import Foundation
import Testing
@testable import HLProtocol

/// The `call_event` JSON this app writes (and the states its test phones send) against `shared/schemas/call_event-*`.
@Suite("call_event messages against the shared JSON Schemas")
struct CallSchemaConformanceTests {
    let validator: SchemaValidator

    init() throws {
        validator = try SchemaValidator()
    }

    private func expectValid(_ data: Data, _ ref: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let errors = validator.errors(try JSONSerialization.jsonObject(with: data), ref: ref)
        #expect(errors.isEmpty, "\(ref): \(errors)", sourceLocation: sourceLocation)
    }

    private func expectInvalid(_ json: String, _ ref: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let errors = validator.errors(try JSONSerialization.jsonObject(with: Data(json.utf8)), ref: ref)
        #expect(!errors.isEmpty, "\(ref) must refuse \(json)", sourceLocation: sourceLocation)
    }

    static let callId = "0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90"

    static func states() -> [CallStateData] {
        [
            CallStateData(callId: callId, direction: .incoming, state: .ringing, number: "+84900000123",
                          displayName: "Nguyễn Văn A", presentation: .allowed, subId: 1, simLabel: "SIM 1",
                          startedAt: 1_727_150_400_123, controls: CallControls(answer: true, reject: true)),
            CallStateData(callId: callId, direction: .incoming, state: .ringing, number: nil, displayName: nil,
                          presentation: .restricted, startedAt: 1_727_150_400_123, controls: CallControls(reject: true)),
            CallStateData(callId: callId, direction: .incoming, state: .offhook, number: "+84900000123",
                          displayName: nil, presentation: .allowed, startedAt: 1_727_150_400_123,
                          answeredAt: 1_727_150_405_321, controls: CallControls(end: true)),
            CallStateData(callId: callId, direction: .incoming, state: .ringing, waiting: true, number: "+84900000123",
                          displayName: nil, presentation: .allowed, waitingNumber: "+84900000456",
                          startedAt: 1_727_150_400_123, answeredAt: 1_727_150_405_321, controls: .none),
            CallStateData(callId: callId, direction: .outgoing, state: .offhook, number: nil, displayName: nil,
                          presentation: .unknown, startedAt: 1_727_150_400_123, controls: CallControls(end: true)),
            CallStateData(callId: callId, direction: .incoming, state: .idle, number: "+84900000123",
                          displayName: "Nguyễn Văn A", presentation: .allowed, subId: 1, simLabel: "SIM 1",
                          startedAt: 1_727_150_400_123, endedAt: 1_727_150_425_456, endReason: .missed,
                          controls: .none),
        ]
    }

    @Test("call_event/state of the test phones: ringing, withheld, offhook, waiting, outgoing, missed")
    func states() throws {
        for state in Self.states() {
            try expectValid(try TypedPayload(op: "state", data: state).encoded(), "call_event-state.schema.json")
        }
    }

    @Test("call_event/action written by this app, and the acks it reads")
    func actions() throws {
        for request in [CallActionRequest(callId: Self.callId, action: .answer, audio: .phone),
                        CallActionRequest(callId: Self.callId, action: .answer),
                        CallActionRequest(callId: Self.callId, action: .reject),
                        CallActionRequest(callId: Self.callId, action: .end)] {
            try expectValid(try TypedPayload(op: "action", data: request).encoded(), "call_event-action.schema.json")
        }
        try expectValid(try Ack.success(re: HLUUID.v7()).encoded(), "call_event-action.schema.json#/$defs/ack")
        let refused = Ack.failure(re: HLUUID.v7(), error: AckError(
            code: .callActionNotAllowed, message: "Call is no longer ringing",
            details: try HLJSON.convert(from: CallActionNotAllowedDetails(state: .offhook, reason: .state))))
        try expectValid(try refused.encoded(), "call_event-action.schema.json#/$defs/ack-failure")
    }

    @Test("call_event/log_sync requests, a page ack, and log_new")
    func callLog() throws {
        try expectValid(try TypedPayload(op: "log_sync", data: CallLogSyncRequest(cursor: nil)).encoded(),
                        "call_event-log_sync.schema.json")
        try expectValid(try TypedPayload(op: "log_sync", data: CallLogSyncRequest(cursor: "eyJ2IjoxLCJpZCI6NTEyMH0"))
            .encoded(), "call_event-log_sync.schema.json")
        let entries = [
            CallLogEntryData(entryId: 5119, number: "+84900000456", displayName: nil, type: .outgoing,
                             ts: 1_727_140_000_000, durationS: 62, subId: 1),
            CallLogEntryData(entryId: 5120, number: nil, displayName: nil, type: .missed, ts: 1_727_150_400_123,
                             durationS: 0, subId: nil),
        ]
        let page = CallLogSyncAckData(entries: entries, cursor: "eyJ2IjoxLCJpZCI6NTEyMH0", hasMore: false, reset: false)
        try expectValid(try Ack.success(re: HLUUID.v7(), data: HLJSON.convert(from: page)).encoded(),
                        "call_event-log_sync.schema.json#/$defs/ack")
        for callId in [Self.callId, nil] {
            try expectValid(try TypedPayload(op: "log_new", data: CallLogNewData(entry: entries[1], callId: callId))
                .encoded(), "call_event-log_new.schema.json")
        }
    }

    @Test("The checker refuses broken call messages (checks the checker)")
    func brokenSamples() throws {
        let ringing = try #require(String(bytes: try TypedPayload(op: "state", data: Self.states()[0]).encoded(),
                                          encoding: .utf8))
        try expectInvalid(ringing.replacingOccurrences(of: #""ended_at":null"#, with: #""ended_at":1"#),
                          "call_event-state.schema.json")
        try expectInvalid(ringing.replacingOccurrences(of: #""sub_id":1"#, with: #""sub_id":"1""#),
                          "call_event-state.schema.json")
        try expectInvalid(#"{"op":"action","data":{"call_id":"\#(Self.callId)","action":"reject","audio":"mac"}}"#,
                          "call_event-action.schema.json")
        try expectInvalid(#"{"op":"log_sync","data":{"limit":0}}"#, "call_event-log_sync.schema.json")
        try expectInvalid(#"{"op":"log_new","data":{"entry":{"entry_id":1,"number":null,"display_name":null,"#
            + #""type":"video","ts":1,"duration_s":0,"sub_id":null},"call_id":null}}"#, "call_event-log_new.schema.json")
    }
}
