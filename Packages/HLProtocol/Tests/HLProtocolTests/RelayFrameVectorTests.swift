import Foundation
import Testing
@testable import HLProtocol

/// `shared/test-vectors/relay-frame.json` (S2.3): the `HR` binary frame and the `to` → `from` rewrite of 0.4.3.
@Suite("relay-frame.json")
struct RelayFrameVectorTests {
    let file: VectorFile

    init() throws {
        file = try VectorFile("relay-frame.json")
    }

    static func hex(_ text: String) throws -> Data {
        var data = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { throw VectorError.badHex(text) }
            data.append(byte)
            index = next
        }
        return data
    }

    @Test("HR frames: header, device_id and the intact HL frame, both ways")
    func frames() throws {
        for vector in file.vectors where vector["kind"] as? String == "frame" {
            let bytes = try Self.hex(try vector.string("frame"))
            let frame = try HRFrame.parse(bytes)
            #expect(frame.deviceId == (try vector.string("device_id")), "\(vector.label)")
            #expect(frame.hlFrame == (try Self.hex(try vector.string("inner"))), "\(vector.label)")
            #expect(try frame.encoded() == bytes, "\(vector.label)")
        }
        for vector in file.vectors where vector["kind"] as? String == "rewrite" {
            let outbound = try HRFrame.parse(try Self.hex(try vector.string("outbound")))
            let inbound = try HRFrame.parse(try Self.hex(try vector.string("inbound")))
            #expect(outbound.deviceId == (try vector.string("recipient_device_id")), "\(vector.label)")
            #expect(inbound.deviceId == (try vector.string("sender_device_id")) && inbound.hlFrame == outbound.hlFrame)
        }
    }

    @Test("Text wrapper: the client writes the compact outbound form and reads every inbound form")
    func textRewrite() throws {
        for vector in file.vectors where vector["kind"] as? String == "text_rewrite" {
            let envelope = try Envelope.parse(Data(try vector.string("env").utf8))
            let inbound = try RelayFrame.parse(try vector.string("inbound"))
            #expect(inbound == .forward(from: try vector.string("sender_device_id"), envelope: envelope), "\(vector.label)")
            if vector["spoofed_from"] == nil, (try vector.string("outbound")).hasPrefix("{\"to\"") {
                let written = try RelayFrame.forward(to: try vector.string("recipient_device_id"), envelope: envelope)
                #expect(written == (try vector.string("outbound")), "\(vector.label)")
            }
        }
    }

    @Test("Frames and wrappers the relay refuses are refused here too")
    func invalid() throws {
        for vector in file.invalidVectors {
            if vector["kind"] as? String == "frame" {
                let bytes = try Self.hex(try vector.string("frame"))
                #expect(throws: ProtocolError.self, "\(vector.label)") { try HRFrame.parse(bytes) }
            }
        }
        let envelope = Envelope(type: .sms, id: HLUUID.v7(), ts: 1, payload: "AAAA")
        #expect(throws: ProtocolError.invalidField("to")) { try RelayFrame.forward(to: "phone", envelope: envelope) }
    }
}
