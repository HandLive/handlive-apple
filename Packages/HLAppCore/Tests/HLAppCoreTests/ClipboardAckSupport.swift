import Foundation
import HLProtocol
@testable import HLAppCore

extension Ack {
    /// The `ClipboardAckData` of an `ack`, from `data` or, for a refusal, from `error.details`.
    var clipboardData: ClipboardAckData? {
        (ok ? data : error?.details).flatMap { try? HLJSON.convert($0, to: ClipboardAckData.self) }
    }
}
