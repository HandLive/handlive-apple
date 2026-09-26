import Foundation
import Testing
@testable import HLProtocol

/// 0.4.3 and 0.7.3: the routing wrapper, the control ops and the `HR` binary frame; the REST bodies of 0.7.4 use the
/// wire names of the examples in CONN-03, CONN-04, PAIR-01, PAIR-02 and PAIR-03.
@Suite("relay frames and REST bodies")
struct RelayFramesTests {
    static let phone = "8c7d6e5f-4a3b-8c2d-9e1f-0a1b2c3d4e5f"
    static let mac = "5b1f8c2e-9a4d-8e6f-a1b2-c3d4e5f60718"
    static let envelope = Envelope(type: .sms, id: "0192f4b2-5c6d-7e8f-9a0b-1c2d3e4f5a6b", ts: 1_727_151_200_000,
                                   payload: Base64Coding.encodeB64(Data([1, 2, 3])))

    static func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test("Forwarding wrapper of CONN-03 API 6: to on the way out, from on the way in")
    func forwarding() throws {
        let outgoing = try RelayFrame.forward(to: Self.phone, envelope: Self.envelope)
        let object = try Self.object(outgoing)
        #expect(object["to"] as? String == Self.phone)
        #expect(try Envelope.parse(JSONSerialization.data(withJSONObject: object["env"] as Any)) == Self.envelope)
        let incoming = #"{"from":"\#(Self.mac)","env":\#(Self.envelope.wireString())}"#
        #expect(try RelayFrame.parse(incoming) == .forward(from: Self.mac, envelope: Self.envelope))
        #expect(throws: ProtocolError.invalidField("to")) { try RelayFrame.forward(to: "PHONE", envelope: Self.envelope) }
    }

    @Test("Control ops: presence, error, pair_revoked, an unknown op")
    func controls() throws {
        let presence = #"{"op":"presence","pair_id":"3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d","#
            + #""peer_device_id":"8c7d6e5f-4a3b-8c2d-9e1f-0a1b2c3d4e5f","online":true}"#
        #expect(try RelayFrame.parse(presence) == .control(.presence(pairId: "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
                                                                     peerDeviceId: Self.phone, online: true)))
        let error = #"{"op":"error","code":"NOT_CONNECTED","message":"peer offline","to":"\#(Self.phone)"}"#
        #expect(try RelayFrame.parse(error) == .control(.error(code: .notConnected, message: "peer offline", to: Self.phone)))
        let newer = #"{"op":"error","code":"SLOW_DOWN","message":""}"#
        #expect(try RelayFrame.parse(newer) == .control(.error(code: .unrecognized, message: "", to: nil)))
        let revoked = #"{"op":"pair_revoked","pair_id":"3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d","by":"\#(Self.phone)"}"#
        #expect(try RelayFrame.parse(revoked) == .control(.pairRevoked(pairId: "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
                                                                        by: Self.phone)))
        #expect(try RelayFrame.parse(#"{"op":"stats","n":1}"#) == .control(.unknown(op: "stats")))
        #expect(throws: ProtocolError.invalidField("online")) {
            try RelayFrame.parse(#"{"op":"presence","pair_id":"\#(Self.phone)","peer_device_id":"\#(Self.mac)","online":1}"#)
        }
    }

    @Test("Rendezvous of PAIR-01 API 7: rv_join, rv_joined, rv_msg with a pair envelope")
    func rendezvous() throws {
        let join = try RelayFrame.rendezvousJoin(rvId: "Eh8kKS4zOD1CR0xRVltgZQ")
        #expect(join == #"{"op":"rv_join","rv_id":"Eh8kKS4zOD1CR0xRVltgZQ"}"#)
        #expect(try RelayFrame.parse(#"{"op":"rv_joined","rv_id":"Eh8kKS4zOD1CR0xRVltgZQ","peer_present":true}"#)
                == .control(.rendezvousJoined(rvId: "Eh8kKS4zOD1CR0xRVltgZQ", peerPresent: true)))
        let message = #"{"op":"rv_msg","rv_id":"Eh8kKS4zOD1CR0xRVltgZQ","env":{"v":1,"type":"pair","#
            + #""id":"0192f3c1-7c1e-7a55-9d0b-3f4c2a1b9e10","ts":1727150001000,"payload":"eyJvcCI6ImhlbGxvIiwiZGF0YSI6e319"}}"#
        guard case .control(.rendezvousMessage(let rvId, let env)) = try RelayFrame.parse(message) else {
            Issue.record("not an rv_msg")
            return
        }
        #expect(rvId == "Eh8kKS4zOD1CR0xRVltgZQ" && env.type == .pair)
        let rebuilt = try RelayFrame.rendezvousMessage(rvId: rvId, envelope: env)
        #expect(try RelayFrame.parse(rebuilt) == .control(.rendezvousMessage(rvId: rvId, envelope: env)))
        #expect(throws: ProtocolError.invalidField("rv_id")) { try RelayFrame.rendezvousJoin(rvId: "AAAA") }
    }

    @Test("HR frame: header, device_id and the intact HL frame; wrong magic, version or op are refused")
    func hrFrame() throws {
        let hl = HLFrame(header: HLFrameHeader(seq: 1, ts: 2), encrypted: Data(repeating: 9, count: 40)).bytes
        let frame = HRFrame(deviceId: Self.phone, hlFrame: hl)
        let bytes = try frame.encoded()
        #expect(Array(bytes.prefix(4)) == [0x48, 0x52, 0x01, 0x01] && bytes.count == 20 + hl.count)
        #expect(try HRFrame.parse(bytes) == frame)
        var wrong = bytes
        wrong[3] = 0x02
        #expect(throws: ProtocolError.invalidFrame("op")) { try HRFrame.parse(wrong) }
        wrong = bytes
        wrong[2] = 0x02
        #expect(throws: ProtocolError.invalidFrame("ver")) { try HRFrame.parse(wrong) }
        #expect(throws: ProtocolError.invalidFrame("length")) { try HRFrame.parse(bytes.prefix(20)) }
    }

    @Test("REST bodies keep the wire names of the examples")
    func restBodies() throws {
        let push = try HLJSON.decode(RelayPushRequest.self, from: Data((#"{"pair_id":"7a6b5c4d-3e2f-4a1b-9c8d-7e6f5a4b3c2d","#
            + #""to":"2c3d4e5f-6a7b-8c9d-8e0f-1a2b3c4d5e6f","kind":"alert","reason":"sms_new","env_b64":"eyJ2IjoxfQ==","#
            + #""collapse_key":"sms:118","ttl_s":86400}"#).utf8))
        #expect(push.kind == .alert && push.reason == .smsNew && push.ttlS == 86_400)
        let wake = RelayPushRequest(pairId: push.pairId, to: Self.phone, kind: .wake, reason: .userOpen)
        #expect(try SmsMessagesTests.keys(wake) == ["pair_id", "to", "kind", "reason"])
        let token = RelayPushTokenRequest(provider: .apnsSandbox, token: "4f1c2ea9", topic: "app.handlive.ios")
        #expect(String(data: try HLJSON.encode(token), encoding: .utf8)
                == #"{"provider":"apns_sandbox","token":"4f1c2ea9","topic":"app.handlive.ios"}"#)
        let pairs = try HLJSON.decode(RelayPairList.self, from: Data((#"{"pairs":[{"#
            + #""pair_id":"3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d","peer_device_id":"8c7d6e5f-4a3b-8c2d-9e1f-0a1b2c3d4e5f","#
            + #""peer_platform":"android","created_at":1727150003210,"revoked_at":null,"peer_online":true}]}"#).utf8))
        #expect(pairs.pairs.first?.peerPlatform == .android && pairs.pairs.first?.revokedAt == nil)
        let error = try HLJSON.decode(RelayErrorBody.self, from: Data(#"{"error":{"code":"TOKEN_EXPIRED","message":"x"}}"#.utf8))
        #expect(error.error.code == .tokenExpired)
        #expect(String(data: try HLJSON.encode(RelayPairRevokeRequest(reason: .lostDevice)), encoding: .utf8)
                == #"{"reason":"lost_device"}"#)
    }

    @Test("Registration and token bodies of relay-auth.json")
    func authVectors() throws {
        for vector in try VectorFile("relay-auth.json").vectors {
            let request = try Self.object(try vector.string("request"))
            let encoded: Data
            if try vector.string("kind") == "register" {
                encoded = try HLJSON.encode(HLJSON.decode(RelayDeviceRegistration.self,
                                                          from: Data(try vector.string("request").utf8)))
            } else {
                encoded = try HLJSON.encode(HLJSON.decode(RelayTokenRequest.self, from: Data(try vector.string("request").utf8)))
            }
            let reencoded = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(NSDictionary(dictionary: reencoded) == NSDictionary(dictionary: request))
        }
    }

    @Test("APNs fields p and hl (CONN-04 API 4)")
    func pushFields() throws {
        let hl = Base64Coding.encodeB64(Self.envelope.wireData())
        let fields = try #require(PushAlertFields(userInfo: ["aps": ["mutable-content": 1], "p": Self.mac, "hl": hl]))
        #expect(fields.pairId == Self.mac && fields.envelope == Self.envelope)
        #expect(PushAlertFields(userInfo: ["p": Self.mac]) == nil)
        #expect(PushAlertFields(userInfo: ["p": "x", "hl": hl]) == nil)
        #expect(PushAlertFields(userInfo: ["p": Self.mac, "hl": "not base64"]) == nil)
    }
}
