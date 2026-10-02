import Foundation
import Testing
@testable import HLProtocol

/// The `app_call` JSON the test phones send and this app's capability against `shared/schemas/call_event-app_call`.
/// The checks run once the shared repository has the schema (it is written by the contract step of CALL-05).
private let appCallSchema = "call_event-app_call.schema.json"
private let appCallSchemaExists = FileManager.default.fileExists(
    atPath: RepoFiles.schemasDirectory.appendingPathComponent(appCallSchema).path)

@Suite("call_event/app_call against the shared JSON Schema",
       .enabled(if: appCallSchemaExists, "shared/schemas has no call_event-app_call yet"))
struct AppCallSchemaConformanceTests {
    let validator: SchemaValidator

    init() throws {
        validator = try SchemaValidator()
    }

    private func errors(_ json: String) throws -> [String] {
        validator.errors(try JSONSerialization.jsonObject(with: Data(json.utf8)), ref: appCallSchema)
    }

    @Test("Ringing (tap), ongoing without a caller and ended samples are valid; the typed encoder writes valid JSON")
    func validSamples() throws {
        for json in [AppCallMessagesTests.ringing, AppCallMessagesTests.ongoing, AppCallMessagesTests.ended] {
            let found = try errors(json)
            #expect(found.isEmpty, "\(found)")
            let data = try AppCallMessagesTests.payload(json).decodeData(as: AppCallData.self)
            let written = try #require(String(bytes: TypedPayload(op: "app_call", data: data).encoded(), encoding: .utf8))
            let writtenErrors = try errors(written)
            #expect(writtenErrors.isEmpty, "\(writtenErrors)")
        }
    }

    @Test("The checker refuses broken app_call messages (checks the checker)")
    func brokenSamples() throws {
        let ringing = AppCallMessagesTests.ringing
        let broken = [
            ringing.replacingOccurrences(of: #""state":"ringing""#, with: #""state":"screening""#),
            ringing.replacingOccurrences(of: #""end_reason":null"#, with: #""end_reason":"declined""#),
            ringing.replacingOccurrences(of: #""end":false"#, with: #""end":true"#),
            ringing.replacingOccurrences(of: #""audio":"phone""#, with: #""audio":"mac""#),
            ringing.replacingOccurrences(of: #""package":"org.telegram.messenger","#, with: ""),
        ]
        for json in broken {
            let found = try errors(json)
            #expect(!found.isEmpty, "must refuse \(json)")
        }
    }

    @Test("A capability with features.call.app_calls is valid, for the Mac (true) and iPhone/iPad (false)")
    func capability() throws {
        for appCalls in [true, false] {
            let device = CapabilityData(appVersion: "1.0.0 (100)", platform: appCalls ? .macos : .ios, osVersion: "15.1",
                                        model: "Mac15,3",
                                        features: Features(call: CallFeature(enabled: true, appCalls: appCalls)))
            let data = try TypedPayload(op: "hello", data: device).encoded()
            let found = validator.errors(try JSONSerialization.jsonObject(with: data), ref: "capability-hello.schema.json")
            #expect(found.isEmpty, "\(found)")
        }
    }
}
