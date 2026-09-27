import Foundation
import Testing
@testable import HLProtocol

/// 05-sms.md: every payload and ack example of SMS-01…05 decodes into the typed `data`, and encoding uses the wire
/// names (absent optionals left out, `display_name` kept as `null`).
@Suite("sms ops: sync, history, new, send, status, read_changed")
struct SmsMessagesTests {
    static func payload(_ json: String) throws -> Payload {
        try Payload.parse(Data(json.utf8))
    }

    static func ack(_ json: String) throws -> Ack {
        try HLJSON.decode(Ack.self, from: Data(json.utf8))
    }

    static func keys(_ value: some Encodable) throws -> Set<String> {
        Set((try JSONSerialization.jsonObject(with: HLJSON.encode(value)) as? [String: Any])?.keys.map { $0 } ?? [])
    }

    @Test("First sync of SMS-01 API 1: request, first page with page_token")
    func firstSync() throws {
        let request = try Self.payload(#"{"op":"sync","data":{"thread_limit":200,"per_thread_limit":50}}"#)
            .decodeData(as: SmsSyncRequest.self)
        #expect(request == SmsSyncRequest(cursor: nil))
        #expect(try Self.keys(request) == ["thread_limit", "per_thread_limit"])
        let ack = try Self.ack(#"{"re":"0192f3e0-1a2b-7c3d-8e4f-5a6b7c8d9e01","ok":true,"data":{"threads":[{"thread_id":42,"#
            + #""addresses":["+84900000123"],"display_name":"Nguyễn Văn A","snippet":"Chiều nay 3h họp nhé","#
            + #""last_ts":1727150000123,"unread_count":1}],"messages":[{"message_key":"sms:12846","thread_id":42,"#
            + #""address":"+84900000123","body":"Chiều nay 3h họp nhé","box":"inbox","ts":1727150000123,"#
            + #""ts_sent":1727149998000,"read":false,"sub_id":1},{"message_key":"sms:12790","thread_id":42,"#
            + #""address":"+84900000123","body":"Ok anh","box":"sent","ts":1727140000000,"ts_sent":null,"read":true,"#
            + #""sub_id":1}],"cursor":"eyJ2IjoxLCJpZCI6MTI4NDYsInQiOjE3MjcxNTAwMDAxMjN9","#
            + #""page_token":"eyJ2IjoxLCJtIjoxMjg0NiwidGgiOls0Miw1Nyw2M10sIm8iOjIwfQ","has_more":true}}"#)
        let page = try HLJSON.convert(try #require(ack.data), to: SmsSyncAckData.self)
        #expect(page.hasMore && page.pageToken != nil && page.unread == nil)
        #expect(page.threads.first?.displayName == "Nguyễn Văn A" && page.threads.first?.unreadCount == 1)
        #expect(page.messages.map(\.box) == [.inbox, .sent])
        #expect(page.messages[1].tsSent == nil && page.messages[0].tsSent == 1_727_149_998_000)
        #expect(page.messages.allSatisfy { $0.localId == nil })
    }

    @Test("Catch-up sync of SMS-01 API 1: the last page carries unread")
    func catchUpSync() throws {
        let request = try Self.payload(#"{"op":"sync","data":{"cursor":"eyJ2IjoxLCJpZCI6MTI4NDYsInQiOjE3MjcxNTAwMDAxMjN9","#
            + #""thread_limit":200,"per_thread_limit":50}}"#).decodeData(as: SmsSyncRequest.self)
        #expect(request.cursor == "eyJ2IjoxLCJpZCI6MTI4NDYsInQiOjE3MjcxNTAwMDAxMjN9" && request.pageToken == nil)
        let ack = try Self.ack(#"{"re":"0192f3e0-3c4d-7e5f-9a6b-7c8d9e0f1a23","ok":true,"data":{"threads":[{"thread_id":42,"#
            + #""addresses":["+84900000123"],"display_name":"Nguyễn Văn A","snippet":"Nhớ mang theo tài liệu","#
            + #""last_ts":1727150060456,"unread_count":2}],"messages":[{"message_key":"sms:12847","thread_id":42,"#
            + #""address":"+84900000123","body":"Nhớ mang theo tài liệu","box":"inbox","ts":1727150060456,"#
            + #""ts_sent":1727150059000,"read":false,"sub_id":1}],"#
            + #""cursor":"eyJ2IjoxLCJpZCI6MTI4NDcsInQiOjE3MjcxNTAwNjA0NTZ9","has_more":false,"#
            + #""unread":[{"thread_id":42,"unread_count":2,"read_up_to_ts":1727150000122}]}}"#)
        let page = try HLJSON.convert(try #require(ack.data), to: SmsSyncAckData.self)
        #expect(!page.hasMore && page.pageToken == nil)
        #expect(page.unread == [SmsReadState(threadId: 42, unreadCount: 2, readUpToTs: 1_727_150_000_122)])
    }

    @Test("History of SMS-03 API 1 and its SMS_THREAD_NOT_FOUND error")
    func history() throws {
        let request = try Self.payload(#"{"op":"history","data":{"thread_id":42,"before_ts":1727140000000,"limit":50}}"#)
            .decodeData(as: SmsHistoryRequest.self)
        #expect(request == SmsHistoryRequest(threadId: 42, beforeTs: 1_727_140_000_000))
        let ack = try Self.ack(#"{"re":"0192f3e1-2b3c-7d4e-9f50-6a7b8c9d0e12","ok":true,"data":{"messages":[{"#
            + #""message_key":"sms:12611","thread_id":42,"address":"+84900000123","body":"Anh gửi em file báo cáo nhé","#
            + #""box":"inbox","ts":1727052000000,"ts_sent":1727051998000,"read":true,"sub_id":1}],"has_more":false}}"#)
        let page = try HLJSON.convert(try #require(ack.data), to: SmsHistoryAckData.self)
        #expect(page.messages.count == 1 && !page.hasMore)
        let failure = try Self.ack(#"{"re":"0192f3e1-2b3c-7d4e-9f50-6a7b8c9d0e12","ok":false,"error":{"#
            + #""code":"SMS_THREAD_NOT_FOUND","message":"Conversation no longer exists on the phone","details":{}}}"#)
        #expect(failure.error?.code == .smsThreadNotFound)
    }

    @Test("sms/new of SMS-02 API 1 and the one with local_id of SMS-04 API 4")
    func newMessage() throws {
        let received = try Self.payload(#"{"op":"new","data":{"message":{"message_key":"sms:12847","thread_id":42,"#
            + #""address":"+84900000123","body":"Nhớ mang theo tài liệu","box":"inbox","ts":1727150060456,"#
            + #""ts_sent":1727150059000,"read":false,"sub_id":1},"thread":{"thread_id":42,"addresses":["+84900000123"],"#
            + #""display_name":"Nguyễn Văn A","snippet":"Nhớ mang theo tài liệu","last_ts":1727150060456,"#
            + #""unread_count":2}}}"#).decodeData(as: SmsNewData.self)
        #expect(received.message.box == .inbox && received.thread.unreadCount == 2 && received.message.localId == nil)
        let sent = try Self.payload(#"{"op":"new","data":{"message":{"message_key":"sms:12848","thread_id":42,"#
            + #""address":"+84900000123","body":"Ok, 3h mình có mặt","box":"sent","ts":1727150125000,"ts_sent":null,"#
            + #""read":true,"sub_id":1,"local_id":"0192f3e2-4b5c-7d6e-9f70-8a9b0c1d2e3f"},"thread":{"thread_id":42,"#
            + #""addresses":["+84900000123"],"display_name":"Nguyễn Văn A","snippet":"Ok, 3h mình có mặt","#
            + #""last_ts":1727150125000,"unread_count":2}}}"#).decodeData(as: SmsNewData.self)
        #expect(sent.message.localId == "0192f3e2-4b5c-7d6e-9f70-8a9b0c1d2e3f" && sent.message.box == .sent)
    }

    @Test("A thread without a contact name encodes display_name as null; an unknown box still decodes")
    func nullsAndUnknowns() throws {
        let thread = SmsThreadData(threadId: 7, addresses: ["VIETTEL"], displayName: nil, snippet: "", lastTs: 1,
                                   unreadCount: 0)
        let object = try JSONSerialization.jsonObject(with: HLJSON.encode(thread)) as? [String: Any]
        #expect(object?["display_name"] is NSNull)
        let message = try HLJSON.decode(SmsMessageData.self, from: Data((#"{"message_key":"sms:1","thread_id":7,"#
            + #""address":"VIETTEL","body":"","box":"scheduled","ts":1,"read":true,"sub_id":null}"#).utf8))
        #expect(message.box == .unrecognized && message.subId == nil)
    }

    @Test("sms/send of SMS-04 API 1: request, ack, SMS_SIM_UNAVAILABLE with details")
    func send() throws {
        let request = try Self.payload(#"{"op":"send","data":{"local_id":"0192f3e2-4b5c-7d6e-9f70-8a9b0c1d2e3f","#
            + #""thread_id":42,"addresses":["+84900000123"],"body":"Ok, 3h mình có mặt","sub_id":1}}"#)
            .decodeData(as: SmsSendRequest.self)
        #expect(request.addresses == ["+84900000123"] && request.subId == 1 && request.threadId == 42)
        let newNumber = SmsSendRequest(localId: request.localId, threadId: nil, addresses: ["+84900000999"], body: "Hi",
                                       subId: nil)
        #expect(try Self.keys(newNumber) == ["local_id", "addresses", "body"])
        let ack = try Self.ack(#"{"re":"0192f3e2-5c6d-7e7f-8a9b-0c1d2e3f4a5b","ok":true,"data":{"accepted":true,"parts":1}}"#)
        #expect(try HLJSON.convert(try #require(ack.data), to: SmsSendAckData.self) == SmsSendAckData(accepted: true, parts: 1))
        let failure = try Self.ack(#"{"re":"0192f3e2-5c6d-7e7f-8a9b-0c1d2e3f4a5b","ok":false,"error":{"#
            + #""code":"SMS_SIM_UNAVAILABLE","message":"Selected SIM is not active","details":{"sims":[1]}}}"#)
        #expect(failure.error?.code == .smsSimUnavailable && failure.error?.details == .object(["sims": .array([.int(1)])]))
    }

    @Test("sms/status of SMS-04 API 2 and sms/read_changed of SMS-05 API 1")
    func statusAndReadChanged() throws {
        let sending = try Self.payload(#"{"op":"status","data":{"local_id":"0192f3e2-4b5c-7d6e-9f70-8a9b0c1d2e3f","#
            + #""status":"sending"}}"#).decodeData(as: SmsStatusData.self)
        #expect(sending.status == .sending && sending.messageKey == nil && sending.errorCode == nil)
        let sent = try Self.payload(#"{"op":"status","data":{"local_id":"0192f3e2-4b5c-7d6e-9f70-8a9b0c1d2e3f","#
            + #""message_key":"sms:12848","status":"sent"}}"#).decodeData(as: SmsStatusData.self)
        #expect(sent.status == .sent && sent.messageKey == "sms:12848")
        let failed = try Self.payload(#"{"op":"status","data":{"local_id":"0192f3e2-4b5c-7d6e-9f70-8a9b0c1d2e3f","#
            + #""status":"failed","error_code":"SMS_NO_SERVICE"}}"#).decodeData(as: SmsStatusData.self)
        #expect(failed.status == .failed && failed.errorCode == .smsNoService)
        let read = try Self.payload(#"{"op":"read_changed","data":{"thread_id":42,"unread_count":0,"#
            + #""read_up_to_ts":1727150130000}}"#).decodeData(as: SmsReadState.self)
        #expect(read == SmsReadState(threadId: 42, unreadCount: 0, readUpToTs: 1_727_150_130_000))
        #expect(SmsOp.readChanged.rawValue == "read_changed")
    }

    @Test("ping/ping of CONN-02 API 2")
    func ping() throws {
        let ping = try Self.payload(#"{"op":"ping","data":{"seq":42}}"#).decodeData(as: PingData.self)
        #expect(ping.seq == 42)
        let ack = try HLJSON.decode(PingAckData.self, from: Data(#"{"seq":42,"server_ts":1727151030000}"#.utf8))
        #expect(ack == PingAckData(seq: 42, serverTs: 1_727_151_030_000))
    }
}
