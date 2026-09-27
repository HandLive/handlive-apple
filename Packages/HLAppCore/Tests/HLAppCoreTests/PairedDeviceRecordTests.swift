import Foundation
import HLProtocol
import Testing
@testable import HLAppCore

/// The pair as the relay needs it (PAIR-01 API 8, CONN-03 step 3) and as the connection manager sees it.
@Suite("Paired device record and the relay")
struct PairedDeviceRecordTests {
    static func record() -> PairedDeviceRecord {
        PairedDeviceRecord(pairId: "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d", peerDeviceId: "8c7d6e5f-4a3b-8c2d-9e1f-0a1b2c3d4e5f",
                           peerName: "Pixel", peerModel: "Pixel 8", peerSigningPublicKey: Data(repeating: 1, count: 32),
                           peerKeyAgreementPublicKey: Data(repeating: 2, count: 32),
                           peerCertificateSHA256: Data(repeating: 3, count: 32), attestation: Data([4, 5, 6]),
                           signatureSelf: Data(repeating: 7, count: 64), signaturePeer: Data(repeating: 8, count: 64),
                           createdAt: 1_727_150_003_210)
    }

    @Test("POST /v1/pairs: the phone is device_a with sig_a, this device device_b with sig_b, b64u values")
    func registration() {
        let client = "5b1f8c2e-9a4d-8e6f-a1b2-c3d4e5f60718"
        let body = Self.record().relayRegistration(clientDeviceId: client)
        #expect(body.deviceA == "8c7d6e5f-4a3b-8c2d-9e1f-0a1b2c3d4e5f" && body.deviceB == client)
        #expect(body.attestation == Base64Coding.encodeB64u(Data([4, 5, 6])) && body.createdAt == 1_727_150_003_210)
        #expect(body.sigA == Base64Coding.encodeB64u(Data(repeating: 8, count: 64)))
        #expect(body.sigB == Base64Coding.encodeB64u(Data(repeating: 7, count: 64)))
    }

    @Test("The manager gets the registration only while relay_registered = 0, and the phone's relay switch")
    func pairedPhone() {
        var record = Self.record()
        let prk = Data(repeating: 9, count: 32)
        #expect(record.pairedPhone(clientDeviceId: "c", prk: prk).relayRegistration != nil)
        #expect(record.pairedPhone(clientDeviceId: "c", prk: prk).relayEnabled) // no capability yet: assume on
        record.relayRegistered = true
        record.peerCapability = CapabilityData(appVersion: "1", platform: .android, osVersion: "15", model: "P",
                                               features: Features(relay: RelayFeature(enabled: false)))
        let phone = record.pairedPhone(clientDeviceId: "c", prk: prk)
        #expect(phone.relayRegistration == nil && !phone.relayEnabled)
    }
}
