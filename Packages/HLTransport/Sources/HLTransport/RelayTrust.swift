import CryptoKit
import Foundation
import Security

/// TLS check of the relay (0.4.3, CONN-03 E7): the system validates the chain and the host name as usual, then some
/// certificate of the validated chain must carry a pinned SubjectPublicKeyInfo (ISRG Root X1/X2 or the backup key).
public enum RelayTrust {
    /// `true` when the chain is valid for `host` and contains a pinned key.
    public static func evaluate(_ trust: SecTrust, host: String, pins: Set<Data>) -> Bool {
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        guard SecTrustEvaluateWithError(trust, nil),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate]
        else { return false }
        return chain.contains { certificate in
            spkiSHA256(of: SecCertificateCopyData(certificate) as Data).map(pins.contains) ?? false
        }
    }

    /// SHA-256 of the SubjectPublicKeyInfo of a DER certificate (the "pin-sha256" of RFC 7469).
    public static func spkiSHA256(of certificateDER: Data) -> Data? {
        subjectPublicKeyInfo(of: certificateDER).map { Data(SHA256.hash(data: $0)) }
    }

    /// The complete `subjectPublicKeyInfo` TLV of `Certificate.tbsCertificate` (RFC 5280 §4.1): skip the optional
    /// `[0]` version, then serial number, signature algorithm, issuer, validity and subject.
    static func subjectPublicKeyInfo(of certificateDER: Data) -> Data? {
        let bytes = [UInt8](certificateDER)
        guard let certificate = DERElement.read(bytes, at: 0), certificate.tag == 0x30,
              let tbs = DERElement.read(bytes, at: certificate.contentStart), tbs.tag == 0x30
        else { return nil }
        var offset = tbs.contentStart
        if let first = DERElement.read(bytes, at: offset), first.tag == 0xA0 { offset = first.end }
        for _ in 0..<5 {
            guard let skipped = DERElement.read(bytes, at: offset), skipped.end <= tbs.end else { return nil }
            offset = skipped.end
        }
        guard let spki = DERElement.read(bytes, at: offset), spki.tag == 0x30, spki.end <= tbs.end else { return nil }
        return Data(bytes[offset..<spki.end])
    }
}

/// One DER TLV with a single-byte tag (enough for the X.509 fields walked above).
struct DERElement {
    let tag: UInt8
    let contentStart: Int
    let end: Int

    static func read(_ bytes: [UInt8], at offset: Int) -> DERElement? {
        guard offset + 2 <= bytes.count else { return nil }
        let tag = bytes[offset]
        guard tag & 0x1F != 0x1F else { return nil } // multi-byte tags do not occur here
        var index = offset + 1
        let first = Int(bytes[index])
        index += 1
        var length = first
        if first & 0x80 != 0 {
            let count = first & 0x7F
            guard (1...4).contains(count), index + count <= bytes.count else { return nil }
            length = bytes[index..<index + count].reduce(0) { $0 << 8 | Int($1) }
            index += count
        }
        guard index + length <= bytes.count else { return nil }
        return DERElement(tag: tag, contentStart: index, end: index + length)
    }
}
