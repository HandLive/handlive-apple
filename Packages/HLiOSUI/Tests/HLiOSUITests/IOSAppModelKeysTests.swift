import Foundation
import HLAppCore
import HLCrypto
import Testing
@testable import HLiOSUI

@Suite("iPhone and iPad app model: keys (SET-03)")
@MainActor
struct IOSAppModelKeysTests {
    @Test("A Keychain that refuses the keys → keysFailed with Try Again (SET-03 E1)")
    func keysFailed() {
        let model = makeIOSModel(secrets: FailingSecretStore())
        model.launch()
        #expect(model.phase == .keysFailed)
    }

    @Test("SET-03 API 1 logic 5: builds with different keys keep their own pairs; none is one-sided or lost")
    func buildsWithDifferentKeysKeepTheirData() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("handlive-ios-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        func launched(_ secrets: InMemorySecretStore) -> IOSAppModel { // keys lost → recreated with a new db_key
            let model = makeIOSModel(secrets: secrets, folder: folder)
            model.settings.setupStartedAt = 5
            model.launch()
            return model
        }
        let first = InMemorySecretStore(), second = InMemorySecretStore()
        let pixel = launched(first)
        try pixel.completePairing(pairingResult(name: "Pixel 8"))
        let opened = launched(second) // opened and left without pairing
        #expect(opened.phase == .ready && opened.deviceId != pixel.deviceId && opened.pairedDevice == nil)
        #expect(opened.messages != nil) // SMS runs on its own database instead of staying off
        #expect(launched(first).pairedDevice?.peerName == "Pixel 8")
        try launched(second).completePairing(pairingResult(name: "Galaxy S25")) // saves
        #expect(launched(first).pairedDevice?.peerName == "Pixel 8")
        #expect(launched(second).pairedDevice?.peerName == "Galaxy S25")
    }
}
