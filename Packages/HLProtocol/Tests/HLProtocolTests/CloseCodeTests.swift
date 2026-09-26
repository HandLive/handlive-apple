import Foundation
import Testing
@testable import HLProtocol

@Suite("WebSocket close codes (0.8.3)")
struct CloseCodeTests {
    /// Codes of the 0.8.3 table, read from the spec itself: rows `| 1000 |`, `| 44xx |`, `| 45xx |`.
    private func documentedCodes() throws -> [UInt16] {
        let spec = try String(
            contentsOf: RepoFiles.root.appendingPathComponent("docs/detailed-design/00-common-specs.md"),
            encoding: .utf8
        )
        let section = try #require(spec.components(separatedBy: "### 0.8.3").dropFirst().first?
            .components(separatedBy: "\n## ").first)
        return section.split(separator: "\n").compactMap { line -> UInt16? in
            guard line.hasPrefix("| ") else { return nil }
            let cell = line.dropFirst(2).split(separator: "|").first?.trimmingCharacters(in: .whitespaces) ?? ""
            return UInt16(cell)
        }
    }

    @Test("Every code of the spec table is modelled, in table order")
    func matchesSpecTable() throws {
        let codes = try documentedCodes()
        #expect(codes.contains(4410) && codes.contains(4411) && codes.contains(4429))
        #expect(CloseCode.documented.map(\.rawValue) == codes)
        for code in codes {
            #expect(CloseCode(rawValue: code) != .other(code), "\(code)")
        }
    }

    @Test("Raw values round-trip; unknown codes stay available for logging")
    func roundTrip() {
        for code in CloseCode.documented {
            #expect(CloseCode(rawValue: code.rawValue) == code)
        }
        #expect(CloseCode(rawValue: 1001) == .other(1001))
        #expect(CloseCode(rawValue: 4999).rawValue == 4999)
    }

    @Test("Codes named after an error code map to ErrorCode")
    func errorCodes() {
        #expect(CloseCode.authFailed.errorCode == .authFailed)
        #expect(CloseCode.pairRevoked.errorCode == .pairRevoked)
        #expect(CloseCode.rateLimited.errorCode == .rateLimited)
        #expect(CloseCode.unsupportedVersion.errorCode == .unsupportedVersion)
        #expect(CloseCode.rekeyFailed.errorCode == nil)
        #expect(CloseCode.idleTimeout.errorCode == nil)
        #expect(CloseCode.replaced.errorCode == nil)
    }
}
