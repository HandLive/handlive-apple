import CryptoKit
import Foundation
import Network
import Security
@testable import HLTransport

/// A TLS 1.3 WebSocket server on 127.0.0.1 with a throwaway self-signed identity (made with /usr/bin/openssl,
/// imported in memory), standing in for the phone's A-SVC in integration tests. The identity never leaves the
/// temporary directory and no keychain is touched.
final class TLSTestServer: @unchecked Sendable {
    let port: UInt16
    let certificateSHA256: Data
    private let listener: NWListener
    private let inbox: AsyncStream<WebSocketChannel>
    private var iterator: AsyncStream<WebSocketChannel>.Iterator

    /// `nil` when the platform cannot import an identity in memory (before macOS 15) or openssl is missing.
    static func start() throws -> TLSTestServer? {
        guard #available(macOS 15, *), let identity = try makeIdentity() else { return nil }
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        guard let certificate else { return nil }
        let hash = Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data))

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        let parameters = NWParameters(tls: tls)
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let (stream, continuation) = AsyncStream.makeStream(of: WebSocketChannel.self)
        let queue = DispatchQueue(label: "app.handlive.test-server")
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                if case .ready = state { continuation.yield(WebSocketChannel(connection: connection, queue: queue)) }
            }
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else { return nil }
        return TLSTestServer(listener: listener, port: port, hash: hash, inbox: stream)
    }

    private init(listener: NWListener, port: UInt16, hash: Data, inbox: AsyncStream<WebSocketChannel>) {
        self.listener = listener
        self.port = port
        certificateSHA256 = hash
        self.inbox = inbox
        iterator = inbox.makeAsyncIterator()
    }

    /// Next accepted connection.
    func accept() async -> WebSocketChannel? {
        var copy = iterator
        let channel = await copy.next()
        iterator = copy
        return channel
    }

    func stop() {
        listener.cancel()
    }

    @available(macOS 15, *)
    private static func makeIdentity() throws -> SecIdentity? {
        let openssl = URL(fileURLWithPath: "/usr/bin/openssl")
        guard FileManager.default.isExecutableFile(atPath: openssl.path) else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("handlive-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("key.pem").path
        let cert = directory.appendingPathComponent("cert.pem").path
        let bundle = directory.appendingPathComponent("identity.p12").path
        try run(openssl, ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "1",
                          "-subj", "/CN=handlive-test"])
        try run(openssl, ["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", bundle, "-passout", "pass:test"])
        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: "test", kSecImportToMemoryOnly as String: true]
        guard SecPKCS12Import(try Data(contentsOf: URL(fileURLWithPath: bundle)) as CFData, options as CFDictionary,
                              &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String]
        else { return nil }
        return (identity as! SecIdentity) // swiftlint:disable:this force_cast
    }

    private static func run(_ tool: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
