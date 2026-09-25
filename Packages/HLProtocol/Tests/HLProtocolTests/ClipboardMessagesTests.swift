import Foundation
import Testing
@testable import HLProtocol

/// CLIP-01 API 5–6 and CLIP-03 API 3–5: the payload and ack examples of the spec decode, and encoding uses the wire
/// names and leaves out absent fields.
@Suite("clipboard ops: push, ack data, cancel, conflict")
struct ClipboardMessagesTests {
    static func data(_ json: String) throws -> Payload {
        try Payload.parse(Data(json.utf8))
    }

    @Test("Inline text push of CLIP-01 API 5 and its acks")
    func textPush() throws {
        let push = try Self.data(#"{"op":"push","data":{"clip_id":"0192f3e0-5a21-7b3c-9d4e-1f2a3b4c5d6e","kind":"text","#
            + #""mime":"text/plain","text":"Order number: HL-240917-0042","sensitive":false,"origin_ts":1727150100123,"#
            + #""source":"auto","origin_device_id":"8c7d6e5f-4a3b-8c2d-9e1f-0a1b2c3d4e5f"}}"#)
            .decodeData(as: ClipboardPushData.self)
        #expect(push.kind == .text && push.text == "Order number: HL-240917-0042" && push.transfer == nil)
        #expect(push.source == .auto && push.originTs == 1_727_150_100_123)
        let ack = try HLJSON.convert(JSONValue.object(["clip_id": .string(push.clipId), "status": .string("ignored"),
                                                       "reason": .string("conflict")]), to: ClipboardAckData.self)
        #expect(ack == ClipboardAckData(clipId: push.clipId, status: .ignored, reason: .conflict))
        let encoded = try JSONSerialization.jsonObject(with: HLJSON.encode(push)) as? [String: Any]
        #expect(Set(encoded?.keys ?? [:].keys) == ["clip_id", "kind", "mime", "text", "sensitive", "origin_ts", "source",
                                                  "origin_device_id"])
    }

    @Test("Image push with transfer of CLIP-03 API 3; an unknown source still decodes")
    func imagePush() throws {
        let push = try Self.data(#"{"op":"push","data":{"clip_id":"0192f3f1-2c3d-7e4f-8a5b-6c7d8e9f0a1b","kind":"image","#
            + #""mime":"image/png","transfer":{"transfer_id":"0192f3f1-2c3e-7a10-9b20-c30d40e50f60","size":5242880,"#
            + #""sha256":"n4bQgYhMfWWaL-qgxVrQFaO_TxsrC4Is0V1sFbDwCgg","chunk_size":65536,"chunk_count":80},"width":2880,"#
            + #""height":1800,"sensitive":false,"origin_ts":1727150200456,"source":"watch","#
            + #""origin_device_id":"5b1f8c2e-9a4d-8e6f-a1b2-c3d4e5f60718"}}"#).decodeData(as: ClipboardPushData.self)
        #expect(push.transfer?.chunkCount == 80 && push.transfer?.size == 5_242_880 && push.width == 2880)
        #expect(push.source == .unrecognized && push.text == nil)
    }

    @Test("A null text or transfer from kotlinx counts as absent")
    func explicitNulls() throws {
        let push = try HLJSON.decode(ClipboardPushData.self, from: Data((#"{"clip_id":"0192f3e0-5a21-7b3c-9d4e-1f2a3b4c5d6e","#
            + #""kind":"text","mime":"text/plain","text":"a","transfer":null,"width":null,"height":null,"#
            + #""sensitive":true,"origin_ts":1,"source":"mac","origin_device_id":"5b1f8c2e-9a4d-8e6f-a1b2-c3d4e5f60718"}"#).utf8))
        #expect(push.transfer == nil && push.width == nil && push.sensitive)
    }

    @Test("cancel and conflict examples of CLIP-03 API 5 and CLIP-01 API 6")
    func cancelAndConflict() throws {
        let cancel = try Self.data(#"{"op":"cancel","data":{"transfer_id":"0192f3f1-2c3e-7a10-9b20-c30d40e50f60","#
            + #""reason":"superseded"}}"#).decodeData(as: ClipboardCancelData.self)
        #expect(cancel.reason == .superseded)
        let conflict = try Self.data(#"{"op":"conflict","data":{"clip_id":"0192f3e0-5a21-7b3c-9d4e-1f2a3b4c5d6e","#
            + #""origin_device_id":"8c7d6e5f-4a3b-8c2d-9e1f-0a1b2c3d4e5f","device_id":"5b1f8c2e-9a4d-8e6f-a1b2-c3d4e5f60718","#
            + #""device_name":"MacBook của Lan"}}"#).decodeData(as: ClipboardConflictData.self)
        #expect(conflict.deviceName == "MacBook của Lan")
    }
}
