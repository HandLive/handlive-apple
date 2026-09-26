import Foundation
import HLProtocol
@testable import HLTransport

/// Two linked in-memory channels: what one sends, the other receives; closing one closes the other with the code.
final class InMemoryChannel: MessageChannel, @unchecked Sendable {
    private let inbox = ChannelInbox()
    private let lock = NSLock()
    private weak var peer: InMemoryChannel?
    private var answersPings = true
    private var closeCodeSeen: CloseCode?

    static func pair() -> (client: InMemoryChannel, phone: InMemoryChannel) {
        let client = InMemoryChannel()
        let phone = InMemoryChannel()
        client.peer = phone
        phone.peer = client
        return (client, phone)
    }

    /// Stops answering pings (a dead link that still looks open).
    func stopAnsweringPings() {
        lock.lock()
        answersPings = false
        lock.unlock()
    }

    /// Close code this side received from its peer, if any.
    var receivedCloseCode: CloseCode? {
        lock.lock()
        defer { lock.unlock() }
        return closeCodeSeen
    }

    func receive() async throws -> ChannelMessage {
        try await inbox.receive()
    }

    func send(_ message: ChannelMessage) async throws {
        if let reason = inbox.closedReason { throw reason }
        guard let peer else { throw ChannelClosed(code: nil, detail: "no peer") }
        peer.inbox.deliver(message)
    }

    private var pingsAnswered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return answersPings && !(peer?.inbox.isClosed ?? true)
    }

    func ping(payload: Data, timeout: Duration) async throws {
        if pingsAnswered { return }
        try await Task.sleep(for: timeout)
        throw ChannelClosed(code: nil, detail: "no pong")
    }

    func close(code: CloseCode) async {
        guard !inbox.isClosed else { return }
        inbox.close(ChannelClosed(code: code, detail: "closed locally", local: true))
        peer?.remoteClosed(code)
    }

    private func remoteClosed(_ code: CloseCode) {
        lock.lock()
        closeCodeSeen = code
        lock.unlock()
        inbox.close(ChannelClosed(code: code, detail: "closed by peer"))
    }
}
