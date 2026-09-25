import CryptoKit
import Foundation
import Security

/// Checks the server's leaf certificate against the policy and remembers its hash (thread-safe: the verify
/// block runs on the connection queue, the result is read after the connection is ready).
final class CertificateCheck: @unchecked Sendable {
    private let policy: CertificatePolicy
    private let lock = NSLock()
    private var hash: Data?
    private var mismatch = false

    init(policy: CertificatePolicy) {
        self.policy = policy
    }

    var certificateSHA256: Data? {
        lock.lock()
        defer { lock.unlock() }
        return hash
    }

    var mismatched: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mismatch
    }

    func verify(_ trust: SecTrust) -> Bool {
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return false }
        let digest = Self.sha256(of: leaf)
        let accepted: Bool
        switch policy {
        case .recordAny: accepted = true
        case .pinned(let pin): accepted = digest == pin
        }
        lock.lock()
        hash = digest
        mismatch = !accepted
        lock.unlock()
        return accepted
    }

    /// SHA-256 of the certificate's DER encoding (the pin of 0.4.1 and `tls_sha256` of PAIR-01).
    static func sha256(of certificate: SecCertificate) -> Data {
        Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data))
    }
}

/// Resumes a checked continuation once, whichever of success, failure, timeout or cancellation comes first.
final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pending: Result<Value, Error>?
    private var done = false

    func set(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let pending {
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(returning value: Value) { resume(with: .success(value)) }
    func resume(throwing error: Error) { resume(with: .failure(error)) }

    private func resume(with result: Result<Value, Error>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        guard let continuation else {
            pending = result
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

extension Duration {
    /// Seconds as `TimeInterval`, for Dispatch deadlines.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
