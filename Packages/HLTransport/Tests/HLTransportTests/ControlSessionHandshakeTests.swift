import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLTransport

@Suite("Control session: handshake (0.6.3, CONN-01)")
struct ControlSessionHandshakeTests {
    @Test("welcome and capability/hello both ways reach Connected")
    func succeeds() async throws {
        let connected = try await SessionHarness.connect()
        #expect(await connected.session.peerCapability == FakePhone.androidCapability)
        #expect(connected.clientCapabilitySeenByPhone == SessionHarness.macCapability)
        #expect(connected.session.route == .lan)
    }

    private func establish(answer: FakePhone.HelloAnswer) async throws -> (SessionEstablishError?, InMemoryChannel) {
        let pair = SessionHarness.pair()
        let (client, phoneChannel) = InMemoryChannel.pair()
        let phone = FakePhone(channel: phoneChannel, pair: pair)
        let answering = Task { try? await phone.answerHello(answer) }
        defer { answering.cancel() }
        do {
            _ = try await ControlSession.establish(over: client, pair: pair, localCapability: SessionHarness.macCapability,
                                                   route: .lan, configuration: SessionHarness.quick())
            return (nil, phoneChannel)
        } catch let error as SessionEstablishError {
            return (error, phoneChannel)
        }
    }

    @Test("session/error PAIR_UNKNOWN → remove the pair (CONN-01 E4)")
    func pairUnknown() async throws {
        let (error, _) = try await establish(answer: .error(.pairUnknown))
        #expect(error == .rejected(.pairUnknown, minProtocol: nil))
        #expect(error?.reaction == .removePair)
    }

    @Test("session/error UNSUPPORTED_VERSION carries min_protocol → update required (E5)")
    func unsupportedVersion() async throws {
        let (error, _) = try await establish(answer: .error(.unsupportedVersion))
        #expect(error == .rejected(.unsupportedVersion, minProtocol: 2))
        #expect(error?.reaction == .updateRequired)
    }

    @Test("session/error AUTH_FAILED → five-minute wait (E3)")
    func authFailedByPhone() async throws {
        let (error, _) = try await establish(answer: .error(.authFailed))
        #expect(error?.reaction == .backoffAfterAuthFailure)
    }

    @Test("welcome with a wrong MAC → close 4401, AUTH_FAILED (step 8)")
    func badWelcomeMac() async throws {
        let (error, phoneChannel) = try await establish(answer: .welcomeWithBadMac)
        #expect(error == .authFailed)
        #expect(phoneChannel.receivedCloseCode == .authFailed)
    }

    @Test("No welcome within HANDSHAKE_TIMEOUT → close 4408 (E6)")
    func timeout() async throws {
        let (error, phoneChannel) = try await establish(answer: .silence)
        #expect(error == .timedOut)
        #expect(phoneChannel.receivedCloseCode == .handshakeTimeout)
        #expect(error?.reaction == .backoff)
    }

    @Test("The phone closes 4429 before answering → back off")
    func rateLimitedBeforeHello() async throws {
        let pair = SessionHarness.pair()
        let (client, phoneChannel) = InMemoryChannel.pair()
        await phoneChannel.close(code: .rateLimited)
        do {
            _ = try await ControlSession.establish(over: client, pair: pair, localCapability: SessionHarness.macCapability,
                                                   route: .lan, configuration: SessionHarness.quick())
            Issue.record("the handshake should fail")
        } catch let error as SessionEstablishError {
            #expect(error == .closed(.rateLimited))
            #expect(error.reaction == .backoff)
        }
    }
}
