import Foundation
import Testing
@testable import HLProtocol

/// `call_event/app_call` (CALL-05): the call of another app on the phone, as the phone sends it, and the commands the
/// Mac sends back with the existing `call_event/action`.
@Suite("call_event op app_call, call.app_calls capability and CALL_APP_ACTION_UNAVAILABLE")
struct AppCallMessagesTests {
    static let callId = "0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90"

    static let ringing = #"{"op":"app_call","data":{"call_id":"0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90","#
        + #""app":{"package":"org.telegram.messenger","label":"Telegram"},"caller":"Nguyễn Văn A","#
        + #""state":"ringing","controls":{"answer":true,"decline":true,"end":false},"answer_mode":"tap","#
        + #""audio":"phone","started_at":1727150400123,"answered_at":null,"ended_at":null,"end_reason":null}}"#

    static let ongoing = #"{"op":"app_call","data":{"call_id":"0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90","#
        + #""app":{"package":"org.telegram.messenger","label":"Telegram"},"caller":null,"#
        + #""state":"ongoing","controls":{"answer":false,"decline":false,"end":true},"answer_mode":"direct","#
        + #""audio":"phone","started_at":1727150400123,"answered_at":1727150405321,"ended_at":null,"end_reason":null}}"#

    static let ended = #"{"op":"app_call","data":{"call_id":"0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90","#
        + #""app":{"package":"org.telegram.messenger","label":"Telegram"},"caller":"Nguyễn Văn A","#
        + #""state":"ended","controls":{"answer":false,"decline":false,"end":false},"answer_mode":"direct","#
        + #""audio":"phone","started_at":1727150400123,"answered_at":1727150405321,"ended_at":1727150425456,"#
        + #""end_reason":"ended"}}"#

    static func payload(_ json: String) throws -> Payload {
        try Payload.parse(Data(json.utf8))
    }

    @Test("A ringing app call decodes with its app, caller, controls and tap-to-answer mode")
    func ringingExample() throws {
        let call = try Self.payload(Self.ringing).decodeData(as: AppCallData.self)
        #expect(call.callId == Self.callId)
        #expect(call.app == AppCallApp(package: "org.telegram.messenger", label: "Telegram"))
        #expect(call.caller == "Nguyễn Văn A" && call.state == .ringing)
        #expect(call.controls == AppCallControls(answer: true, decline: true, end: false))
        #expect(call.answerMode == .tap && call.audio == .phone)
        #expect(call.startedAt == 1_727_150_400_123 && call.answeredAt == nil && call.endedAt == nil)
        #expect(call.endReason == nil)
    }

    @Test("An ongoing call has no caller name when the notification gave none, and an End control")
    func ongoingExample() throws {
        let call = try Self.payload(Self.ongoing).decodeData(as: AppCallData.self)
        #expect(call.caller == nil && call.state == .ongoing && call.answerMode == .direct)
        #expect(call.controls == AppCallControls(answer: false, decline: false, end: true))
        #expect(call.answeredAt == 1_727_150_405_321)
    }

    @Test("An ended call carries ended_at and the reason; every reason decodes")
    func endedExample() throws {
        let call = try Self.payload(Self.ended).decodeData(as: AppCallData.self)
        #expect(call.state == .ended && call.endedAt == 1_727_150_425_456 && call.endReason == .ended)
        #expect(call.controls == .none)
        for reason in ["declined", "ended", "missed", "unknown"] {
            let json = Self.ended.replacingOccurrences(of: #""end_reason":"ended""#, with: #""end_reason":"\#(reason)""#)
            #expect(try Self.payload(json).decodeData(as: AppCallData.self).endReason?.rawValue == reason)
        }
    }

    @Test("app_call encodes every field, the nullable ones as null, and round-trips")
    func encoding() throws {
        let call = try Self.payload(Self.ongoing).decodeData(as: AppCallData.self)
        let object = try #require(JSONSerialization.jsonObject(with: HLJSON.encode(call)) as? [String: Any])
        #expect(object.count == 11)
        #expect(object["caller"] is NSNull && object["ended_at"] is NSNull && object["end_reason"] is NSNull)
        #expect(Set(try #require(object["controls"] as? [String: Any]).keys) == ["answer", "decline", "end"])
        #expect(Set(try #require(object["app"] as? [String: Any]).keys) == ["package", "label"])
        #expect(try HLJSON.decode(AppCallData.self, from: HLJSON.encode(call)) == call)
    }

    @Test("Values from a newer phone decode as unrecognized instead of breaking the message")
    func newerValues() throws {
        let json = Self.ringing.replacingOccurrences(of: #""state":"ringing""#, with: #""state":"screening""#)
            .replacingOccurrences(of: #""answer_mode":"tap""#, with: #""answer_mode":"voice","future":1"#)
            .replacingOccurrences(of: #""audio":"phone""#, with: #""audio":"mac""#)
        let call = try Self.payload(json).decodeData(as: AppCallData.self)
        #expect(call.state == .unrecognized && call.answerMode == .unrecognized && call.audio == .unrecognized)
    }

    @Test("The op name and the call.app_calls capability field")
    func opAndCapability() throws {
        #expect(CallEventOp.appCall.rawValue == "app_call")
        let feature = try HLJSON.decode(CallFeature.self, from: Data(#"{"enabled":true,"app_calls":true}"#.utf8))
        #expect(feature.appCalls == true && feature.notify == nil)
        let encoded = try #require(JSONSerialization.jsonObject(with: HLJSON.encode(
            CallFeature(enabled: true, appCalls: false))) as? [String: Any])
        #expect(encoded["app_calls"] as? Bool == false)
        let legacy = try HLJSON.encode(CallFeature(enabled: true))
        #expect(try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])["app_calls"] == nil)
    }

    @Test("CALL_APP_ACTION_UNAVAILABLE reads from an error ack")
    func unavailableError() throws {
        let ack = try HLJSON.decode(Ack.self, from: Data((#"{"re":"0192f3f1-2c3d-7e4f-9a5b-6c7d8e9f0a12","ok":false,"#
            + #""error":{"code":"CALL_APP_ACTION_UNAVAILABLE","message":"The app no longer offers that action"}}"#).utf8))
        #expect(ack.error?.code == .callAppActionUnavailable)
        #expect(ErrorCode.callAppActionUnavailable.rawValue == "CALL_APP_ACTION_UNAVAILABLE")
    }

    @Test("An app call is answered, declined and ended with the existing call_event/action")
    func actions() throws {
        let answer = CallActionRequest(callId: Self.callId, action: .answer, audio: .phone)
        let bare = CallActionRequest(callId: Self.callId, action: .answer)
        let reject = CallActionRequest(callId: Self.callId, action: .reject)
        let end = CallActionRequest(callId: Self.callId, action: .end)
        for request in [answer, bare, reject, end] {
            let payload = try Self.payload(String(bytes: TypedPayload(op: "action", data: request).encoded(),
                                                  encoding: .utf8) ?? "")
            #expect(try payload.decodeData(as: CallActionRequest.self) == request)
        }
    }
}
