import Foundation
import Testing
@testable import HLProtocol

/// 06-call-control.md: every payload and ack example of CALL-01…04 decodes into the typed `data`, encoding uses the wire
/// names (required nullable fields kept as `null`, absent optionals left out), and values from a newer phone decode.
@Suite("call_event ops: state, action, log_sync, log_new")
struct CallMessagesTests {
    static func payload(_ json: String) throws -> Payload {
        try Payload.parse(Data(json.utf8))
    }

    static func ack(_ json: String) throws -> Ack {
        try HLJSON.decode(Ack.self, from: Data(json.utf8))
    }

    static func object(_ value: some Encodable) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: HLJSON.encode(value)) as? [String: Any] ?? [:]
    }

    static let ringing = #"{"op":"state","data":{"call_id":"0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90","direction":"incoming","#
        + #""state":"ringing","waiting":false,"number":"+84900000123","display_name":"Nguyễn Văn A","#
        + #""presentation":"allowed","sub_id":1,"sim_label":"SIM 1","waiting_number":null,"waiting_display_name":null,"#
        + #""started_at":1727150400123,"answered_at":null,"ended_at":null,"end_reason":null,"controls":{"answer":true,"#
        + #""reject":true,"end":false,"hold":"unavailable","dtmf":"unavailable","mute":"unavailable"},"#
        + #""hfp_connected":false,"audio_on":"phone"}}"#

    @Test("CALL-01 API 1: a ringing call, then missed")
    func stateExamples() throws {
        let ringing = try Self.payload(Self.ringing).decodeData(as: CallStateData.self)
        #expect(ringing.callId == "0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90")
        #expect(ringing.direction == .incoming && ringing.state == .ringing && !ringing.waiting)
        #expect(ringing.number == "+84900000123" && ringing.displayName == "Nguyễn Văn A")
        #expect(ringing.presentation == .allowed && ringing.subId == 1 && ringing.simLabel == "SIM 1")
        #expect(ringing.controls == CallControls(answer: true, reject: true))
        #expect(ringing.endReason == nil && ringing.endedAt == nil && ringing.audioOn == .phone)
        let missed = try Self.payload(#"{"op":"state","data":{"call_id":"0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90","#
            + #""direction":"incoming","state":"idle","waiting":false,"number":"+84900000123","#
            + #""display_name":"Nguyễn Văn A","presentation":"allowed","sub_id":1,"sim_label":"SIM 1","#
            + #""waiting_number":null,"waiting_display_name":null,"started_at":1727150400123,"answered_at":null,"#
            + #""ended_at":1727150425456,"end_reason":"missed","controls":{"answer":false,"reject":false,"end":false,"#
            + #""hold":"unavailable","dtmf":"unavailable","mute":"unavailable"},"hfp_connected":false,"#
            + #""audio_on":"phone"}}"#).decodeData(as: CallStateData.self)
        #expect(missed.state == .idle && missed.endReason == .missed && missed.endedAt == 1_727_150_425_456)
        #expect(missed.controls == .none)
    }

    @Test("CALL-03 API 4: an active call with the Mac on HFP and the audio on the Mac")
    func offhookWithHfp() throws {
        let state = try Self.payload(#"{"op":"state","data":{"call_id":"0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90","#
            + #""direction":"incoming","state":"offhook","waiting":false,"number":"+84900000123","#
            + #""display_name":"Nguyễn Văn A","presentation":"allowed","sub_id":1,"sim_label":"SIM 1","#
            + #""waiting_number":null,"waiting_display_name":null,"started_at":1727150400123,"#
            + #""answered_at":1727150405321,"ended_at":null,"end_reason":null,"controls":{"answer":false,"reject":false,"#
            + #""end":true,"hold":"hfp","dtmf":"hfp","mute":"hfp"},"hfp_connected":true,"audio_on":"mac"}}"#)
            .decodeData(as: CallStateData.self)
        #expect(state.state == .offhook && state.answeredAt == 1_727_150_405_321)
        #expect(state.controls == CallControls(end: true, hold: .hfp, dtmf: .hfp, mute: .hfp))
        #expect(state.hfpConnected && state.audioOn == .mac)
    }

    @Test("state encodes every field, the nullable ones as null")
    func stateEncoding() throws {
        let state = try Self.payload(Self.ringing).decodeData(as: CallStateData.self)
        let object = try Self.object(state)
        #expect(object.count == 18)
        #expect(object["waiting_number"] is NSNull && object["answered_at"] is NSNull && object["end_reason"] is NSNull)
        #expect(try HLJSON.decode(CallStateData.self, from: HLJSON.encode(state)) == state)
    }

    @Test("CALL-02 API 1: answer with its ack, reject refused because the call was answered")
    func actionExamples() throws {
        let answer = try Self.payload(#"{"op":"action","data":{"call_id":"0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90","#
            + #""action":"answer","audio":"phone"}}"#).decodeData(as: CallActionRequest.self)
        #expect(answer == CallActionRequest(callId: "0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90", action: .answer,
                                            audio: .phone))
        #expect(try Self.ack(#"{"re":"0192f3f1-0b2c-7d3e-8f4a-5b6c7d8e9f01","ok":true,"data":{}}"#).ok)
        let reject = try Self.payload(#"{"op":"action","data":{"call_id":"0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90","#
            + #""action":"reject"}}"#).decodeData(as: CallActionRequest.self)
        #expect(reject.action == .reject && reject.audio == nil)
        let refused = try Self.ack(#"{"re":"0192f3f1-2c3d-7e4f-9a5b-6c7d8e9f0a12","ok":false,"error":{"#
            + #""code":"CALL_ACTION_NOT_ALLOWED","message":"Call is no longer ringing","#
            + #""details":{"state":"offhook","reason":"state"}}}"#)
        #expect(refused.error?.code == .callActionNotAllowed)
        let details = try HLJSON.convert(try #require(refused.error?.details), to: CallActionNotAllowedDetails.self)
        #expect(details == CallActionNotAllowedDetails(state: .offhook, reason: .state))
    }

    @Test("CALL-03 API 1: end with its ack, hold refused with CALL_HFP_REQUIRED")
    func endAndHold() throws {
        let end = try Self.payload(#"{"op":"action","data":{"call_id":"0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90","#
            + #""action":"end"}}"#).decodeData(as: CallActionRequest.self)
        #expect(end.action == .end)
        #expect(try Self.ack(#"{"re":"0192f3f2-1a2b-7c3d-9e4f-5a6b7c8d9e0f","ok":true,"data":{}}"#).ok)
        let hold = try Self.ack(#"{"re":"0192f3f2-3c4d-7e5f-8a6b-7c8d9e0f1a2b","ok":false,"error":{"#
            + #""code":"CALL_HFP_REQUIRED","message":"Hold requires Bluetooth HFP","details":{"action":"hold"}}}"#)
        #expect(hold.error?.code == .callHfpRequired)
    }

    @Test("action leaves audio out unless it answers")
    func actionEncoding() throws {
        let id = "0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90"
        #expect(try Set(Self.object(CallActionRequest(callId: id, action: .reject, audio: .mac)).keys)
            == ["call_id", "action"])
        #expect(try Set(Self.object(CallActionRequest(callId: id, action: .answer)).keys) == ["call_id", "action"])
        #expect(try Self.object(CallActionRequest(callId: id, action: .answer, audio: .mac))["audio"] as? String == "mac")
    }

    @Test("CALL-04 API 1: first sync, then an incremental sync")
    func logSyncExamples() throws {
        let first = try Self.payload(#"{"op":"log_sync","data":{"limit":200}}"#).decodeData(as: CallLogSyncRequest.self)
        #expect(first == CallLogSyncRequest(cursor: nil))
        #expect(try Set(Self.object(first).keys) == ["limit"])
        let page = try HLJSON.convert(try #require(try Self.ack(#"{"re":"0192f3f3-5e6f-7a80-9b1c-2d3e4f5a6b7c","#
            + #""ok":true,"data":{"entries":[{"entry_id":5119,"number":"+84900000456","display_name":null,"#
            + #""type":"outgoing","ts":1727140000000,"duration_s":62,"sub_id":1},{"entry_id":5120,"#
            + #""number":"+84900000123","display_name":"Nguyễn Văn A","type":"missed","ts":1727150400123,"#
            + #""duration_s":0,"sub_id":1}],"cursor":"eyJ2IjoxLCJpZCI6NTEyMH0","has_more":false,"reset":false}}"#).data),
            to: CallLogSyncAckData.self)
        #expect(page.entries.map(\.entryId) == [5119, 5120] && page.entries.map(\.type) == [.outgoing, .missed])
        #expect(page.entries[0].displayName == nil && page.entries[0].durationS == 62)
        #expect(page.cursor == "eyJ2IjoxLCJpZCI6NTEyMH0" && !page.hasMore && !page.reset)
        let next = try Self.payload(#"{"op":"log_sync","data":{"cursor":"eyJ2IjoxLCJpZCI6NTEyMH0","limit":200}}"#)
            .decodeData(as: CallLogSyncRequest.self)
        #expect(next.cursor == "eyJ2IjoxLCJpZCI6NTEyMH0" && next.limit == 200)
        let second = try HLJSON.convert(try #require(try Self.ack(#"{"re":"0192f3f3-7a8b-7c9d-8e0f-1a2b3c4d5e6f","#
            + #""ok":true,"data":{"entries":[{"entry_id":5123,"number":"+84900000123","display_name":"Nguyễn Văn A","#
            + #""type":"incoming","ts":1727160000000,"duration_s":125,"sub_id":1}],"#
            + #""cursor":"eyJ2IjoxLCJpZCI6NTEyM30","has_more":false,"reset":false}}"#).data), to: CallLogSyncAckData.self)
        #expect(second.entries.first?.durationS == 125 && second.cursor == "eyJ2IjoxLCJpZCI6NTEyM30")
    }

    @Test("CALL-04 API 2: log_new with its matched call; the entry keeps null fields")
    func logNewExample() throws {
        let new = try Self.payload(#"{"op":"log_new","data":{"entry":{"entry_id":5120,"number":"+84900000123","#
            + #""display_name":"Nguyễn Văn A","type":"missed","ts":1727150400123,"duration_s":0,"sub_id":1},"#
            + #""call_id":"0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90"}}"#).decodeData(as: CallLogNewData.self)
        #expect(new.entry.entryId == 5120 && new.entry.type == .missed)
        #expect(new.callId == "0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90")
        let unmatched = CallLogNewData(entry: CallLogEntryData(entryId: 7, number: nil, displayName: nil, type: .missed,
                                                               ts: 1, durationS: 0, subId: nil), callId: nil)
        let object = try Self.object(unmatched)
        #expect(object["call_id"] is NSNull)
        let entry = try #require(object["entry"] as? [String: Any])
        #expect(entry["number"] is NSNull && entry["display_name"] is NSNull && entry["sub_id"] is NSNull)
    }

    @Test("Values from a newer phone decode as unrecognized instead of breaking the message")
    func newerValues() throws {
        let json = Self.ringing.replacingOccurrences(of: #""state":"ringing""#, with: #""state":"conference""#)
            .replacingOccurrences(of: #""presentation":"allowed""#, with: #""presentation":"payphone""#)
            .replacingOccurrences(of: #""audio_on":"phone""#, with: #""audio_on":"watch","future":1"#)
            .replacingOccurrences(of: #""hold":"unavailable""#, with: #""hold":"cli""#)
        let state = try Self.payload(json).decodeData(as: CallStateData.self)
        #expect(state.state == .unrecognized && state.presentation == .unrecognized && state.audioOn == .unrecognized)
        #expect(state.controls.hold == .unrecognized)
        let entry = try HLJSON.decode(CallLogEntryData.self, from: Data((#"{"entry_id":1,"number":null,"#
            + #""display_name":null,"type":"video","ts":1,"duration_s":0,"sub_id":null}"#).utf8))
        #expect(entry.type == .unrecognized)
    }
}
