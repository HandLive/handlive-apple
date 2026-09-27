import Foundation
import Security

/// Status, body and `Retry-After` of one relay REST response.
public struct RelayHTTPResponse: Sendable, Equatable {
    public let status: Int
    public let body: Data
    /// Seconds of the `Retry-After` header (429, CONN-03 E6).
    public let retryAfter: TimeInterval?

    public init(status: Int, body: Data, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
    }
}

/// Failures below HTTP: the relay could not be reached (E1) or its TLS chain failed the pins (E7).
public enum RelayTransportError: Error, Sendable, Equatable {
    case unreachable(String)
    case pinMismatch
}

/// One HTTP exchange with the relay; `PinnedRelayHTTPTransport` is the real one, tests answer requests themselves.
public protocol RelayHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> RelayHTTPResponse
}

/// URLSession with TLS 1.3 and the SPKI pins of 0.4.3. Each request gets its own ephemeral session, so a pin failure is
/// told apart from other cancellations and nothing (cookies, caches) outlives the request.
public struct PinnedRelayHTTPTransport: RelayHTTPTransport {
    public let configuration: RelayConfiguration
    public var timeout: TimeInterval = 15

    public init(configuration: RelayConfiguration) {
        self.configuration = configuration
    }

    public func send(_ request: URLRequest) async throws -> RelayHTTPResponse {
        let settings = URLSessionConfiguration.ephemeral
        settings.tlsMinimumSupportedProtocolVersion = .TLSv13
        settings.timeoutIntervalForRequest = timeout
        settings.httpCookieStorage = nil
        settings.urlCache = nil
        let pinning = PinningDelegate(host: configuration.host, pins: configuration.spkiPins)
        let session = URLSession(configuration: settings, delegate: pinning, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw RelayTransportError.unreachable("not HTTP") }
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            return RelayHTTPResponse(status: http.statusCode, body: body, retryAfter: retryAfter)
        } catch let error as RelayTransportError {
            throw error
        } catch {
            if pinning.rejected { throw RelayTransportError.pinMismatch }
            throw RelayTransportError.unreachable((error as? URLError)?.code.rawValue.description ?? "network")
        }
    }
}

/// Session delegate that accepts the server only when `RelayTrust` does.
private final class PinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let host: String
    private let pins: Set<Data>
    private let lock = NSLock()
    private var didReject = false

    init(host: String, pins: Set<Data>) {
        self.host = host
        self.pins = pins
    }

    var rejected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didReject
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { return completionHandler(.performDefaultHandling, nil) }
        if RelayTrust.evaluate(trust, host: host, pins: pins) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            lock.lock()
            didReject = true
            lock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
