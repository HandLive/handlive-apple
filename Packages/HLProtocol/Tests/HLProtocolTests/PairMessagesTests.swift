import Foundation
import Testing
@testable import HLProtocol

/// PAIR-01 API 2–6: the payload examples of the spec decode, and the encoded field names are the wire names.
@Suite("pair ops: hello, offer, confirm, done, error (PAIR-01 API 2–6)")
struct PairMessagesTests {
    @Test("pair/hello example of API 2")
    func hello() throws {
        let json = #"{"op":"hello","data":{"mode":"qr","device_id":"5b1f8c2e-9a4d-8e6f-a1b2-c3d4e5f60718","#
            + #""nonce":"xLwqX2J3v3mYqk9jR0l5b0Y4WmR2bUxHQ3N0RU9mZ1U","name":"MacBook của Lan","platform":"macos","#
            + #""model":"Mac15,3","ik_sig_pub":"7Kx9vQ2mTn4pL8rWz1YcHd6fJb3gSa5eUo0iVtNkQxA","#
            + #""ik_dh_pub":"q83vEjRWeJC7zN3u_wARIjNEVWZ3iJmqu8zd7v8AESI"}}"#
        let payload = try Payload.parse(Data(json.utf8))
        #expect(payload.op == PairOp.hello.rawValue)
        let hello = try payload.decodeData(as: PairHelloData.self)
        #expect(hello.mode == .qr && hello.platform == .macos && hello.model == "Mac15,3")
        #expect(hello.ikDhPub == "q83vEjRWeJC7zN3u_wARIjNEVWZ3iJmqu8zd7v8AESI")
        let encoded = try JSONSerialization.jsonObject(with: TypedPayload(op: "hello", data: hello).encoded())
        let data = try #require((encoded as? [String: Any])?["data"] as? [String: Any])
        #expect(Set(data.keys) == ["mode", "device_id", "nonce", "name", "platform", "model", "ik_sig_pub", "ik_dh_pub"])
    }

    @Test("pair/offer example of API 3")
    func offer() throws {
        let json = #"{"op":"offer","data":{"device_id":"8c7d6e5f-4a3b-8c2d-9e1f-0a1b2c3d4e5f","#
            + #""nonce":"n3Jz0b1QdX9pVw8yKq2mLc4tRe6uHs5aGf7iJk0oPlM","name":"Pixel của Lan","model":"Pixel 8","#
            + #""os_version":"15","ik_sig_pub":"Zm9vYmFyYmF6cXV4cXV1eHh5enp6MTIzNDU2Nzg5MDE","#
            + #""ik_dh_pub":"cXdlcnR5dWlvcGFzZGZnaGprbHp4Y3Zibm0xMjM0NTY","#
            + #""tls_sha256":"3q2-7wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","mac":"hM8Qe1vV0x3bKpZ9aLr2sT5wYc7uJd4nFg6iHk8oPqA"}}"#
        let offer = try Payload.parse(Data(json.utf8)).decodeData(as: PairOfferData.self)
        #expect(offer.name == "Pixel của Lan" && offer.osVersion == "15")
        #expect(offer.tlsSha256 == "3q2-7wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
    }

    @Test("pair/confirm and pair/done use pair_id, created_at and prk_check")
    func confirmAndDone() throws {
        let confirm = PairConfirmData(pairId: "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d", createdAt: 1_727_150_003_210,
                                      sig: "s", prkCheck: "p", mac: "m")
        let object = try JSONSerialization.jsonObject(with: HLJSON.encode(confirm)) as? [String: Any]
        #expect(object?["created_at"] as? Int64 == 1_727_150_003_210)
        #expect(Set(object?.keys ?? [:].keys) == ["pair_id", "created_at", "sig", "prk_check", "mac"])
        let done = try HLJSON.decode(PairDoneData.self, from: Data(#"{"sig":"a","prk_check":"b","mac":"c"}"#.utf8))
        #expect(done == PairDoneData(sig: "a", prkCheck: "b", mac: "c"))
    }

    @Test("pair/error: attempts_left only with PIN_INVALID")
    func error() throws {
        let json = #"{"op":"error","data":{"code":"PIN_INVALID","message":"PIN does not match","attempts_left":2}}"#
        let error = try Payload.parse(Data(json.utf8)).decodeData(as: PairErrorData.self)
        #expect(error.code == .pinInvalid && error.attemptsLeft == 2)
        let auth = PairErrorData(code: .authFailed, message: "Pairing authentication failed", attemptsLeft: 1)
        #expect(auth.attemptsLeft == nil)
        let object = try JSONSerialization.jsonObject(with: HLJSON.encode(auth)) as? [String: Any]
        #expect(object?["attempts_left"] == nil)
    }
}
