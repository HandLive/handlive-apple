import Foundation
import HLAppCore
import HLCrypto
import HLLocalization
import HLProtocol
import HLTransport
import Testing
@testable import HLMacUI

@Suite("Mac app model: relay account and Delete All (SET-02 A1–A6, PAIR-03 E3)")
@MainActor
struct AppModelAccountTests {
    /// A launched model paired with a phone whose pair is registered with the relay.
    static func pairedModel(relay: ScriptedRelayAPI, secrets: InMemorySecretStore = InMemorySecretStore(),
                            sms: StubSmsNotifier = StubSmsNotifier()) throws -> AppModel {
        let model = makeModel(secrets: secrets, sms: sms, relay: relay)
        model.launch()
        try model.completePairing(PairingControllerTests.result())
        model.updatePairRecord { $0.relayRegistered = true }
        return model
    }

    @Test("Remove Device from Server: revoke_pairs=false, the pair stays with relay_registered = 0, the relay turns off")
    func removeFromServer() async throws {
        let relay = ScriptedRelayAPI()
        let model = try Self.pairedModel(relay: relay)
        #expect(model.canRemoveFromServer)
        relay.reachable = false
        #expect(await model.removeFromServer() == .failed) // E5: nothing changes
        #expect(model.relayEnabled && model.pairedDevice?.relayRegistered == true)
        relay.reachable = true
        #expect(await model.removeFromServer() == .removed)
        #expect(relay.calls.last == "deleteDevice revoke_pairs=false")
        #expect(model.pairedDevice?.relayRegistered == false && model.pairedDevice != nil)
        #expect(!model.relayEnabled && !model.settings.relayEnabled)
    }

    @Test("Delete All: E7 when the relay can't be reached; deleting anyway erases everything and starts over")
    func deleteAllOffline() async throws {
        let relay = ScriptedRelayAPI()
        let secrets = InMemorySecretStore()
        let sms = StubSmsNotifier()
        let model = try Self.pairedModel(relay: relay, secrets: secrets, sms: sms)
        let pairId = try #require(model.pairedDevice?.pairId)
        let oldDevice = try #require(model.deviceId)
        model.completeSetup()
        relay.reachable = false
        #expect(await model.deleteAllData() == .serverUnreachable)
        #expect(model.pairedDevice?.pairId == pairId) // nothing deleted before the user chooses
        #expect(await model.deleteAllData(evenIfOffline: true) == .deleted)
        #expect(model.pairedDevice == nil && !model.setupCompleted && model.phase == .ready)
        #expect(try secrets.load(account: SecretAccount.pairKey(pairId: pairId)) == nil)
        #expect(model.deviceId != nil && model.deviceId != oldDevice) // a fresh install's keys (SET-03)
        #expect(sms.removedEverything == 1)
        #expect(!FileManager.default.fileExists(atPath: model.pairStoreURL.path))
    }

    @Test("Delete All with the relay reachable deletes this device there with revoke_pairs=true")
    func deleteAllOnline() async throws {
        let relay = ScriptedRelayAPI()
        let model = try Self.pairedModel(relay: relay)
        #expect(await model.deleteAllData() == .deleted)
        #expect(relay.calls.contains("deleteDevice revoke_pairs=true"))
        #expect(model.pairedDevice == nil)
    }

    @Test("Relay problems under the switch: untrusted certificate, removed device, rate limit with its wait")
    func relayProblems() {
        let model = makeModel()
        let now = Date()
        #expect(model.relayProblemText(now: now) == nil)
        model.link = LinkStatus(state: .idle(.notPaired), issue: .relayUntrusted)
        #expect(model.relayProblemText(now: now) == L10n.Error.relayPinMismatch)
        model.link = LinkStatus(state: .idle(.notPaired), issue: .relayDeviceRemoved)
        #expect(model.relayProblemText(now: now) == L10n.Error.relayDeviceRevoked)
        model.link = LinkStatus(state: .idle(.notPaired), nextRetry: now.addingTimeInterval(30), issue: .relayRateLimited)
        let limited = model.relayProblemText(now: now) ?? ""
        #expect(limited.contains("30") && limited != L10n.Error.relayRateLimited(duration: ""))
    }

    @Test("Unpairing a pair on the relay keeps a tombstone until the relay revokes it (PAIR-03 steps 7–9, E3)")
    func tombstone() async throws {
        let relay = ScriptedRelayAPI()
        let model = try Self.pairedModel(relay: relay)
        let store = try #require(model.store)
        relay.reachable = false
        #expect(await model.unpair() == .donePendingRemote)
        #expect(model.pairedDevice == nil)
        #expect(try store.all().map { $0.revokedAt != nil } == [true])
        #expect(await eventually { relay.calls.contains("revokePair lost_device") }) // flow B: the phone was away
        relay.reachable = true
        await model.revokeTombstones()
        #expect(try store.all().isEmpty)
    }
}
