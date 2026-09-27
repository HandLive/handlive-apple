import Foundation
import HLProtocol
import Network
import Testing
@testable import HLTransport

/// How the WebSocket channel reads each completed `receiveMessage` of Network.framework.
@Suite("Received WebSocket frames")
struct ReceivedFrameTests {
    @Test("A close frame that arrives with an error still carries the peer's close code")
    func closeFrameWithError() {
        let frame = ReceivedFrame(opcode: .close, closeCode: .privateCode(4409), data: nil, isComplete: true,
                                  endOfStream: false, error: .posix(.EPIPE))
        #expect(frame.closure?.code == .replaced)
        #expect(frame.closedByPeer)
        #expect(frame.message == nil)
    }

    @Test("A close frame without an error carries its code; 1000 is a normal close")
    func closeFrame() {
        #expect(ReceivedFrame(opcode: .close, closeCode: .privateCode(4403), data: nil, isComplete: true,
                              endOfStream: false, error: nil).closure?.code == .pairRevoked)
        #expect(ReceivedFrame(opcode: .close, closeCode: .protocolCode(.normalClosure), data: nil, isComplete: true,
                              endOfStream: false, error: nil).closure?.code == .normal)
    }

    @Test("A complete message that arrives with an error is delivered before the channel ends without a code")
    func messageWithError() {
        let frame = ReceivedFrame(opcode: .text, closeCode: nil, data: Data("xin chào".utf8), isComplete: true,
                                  endOfStream: false, error: .posix(.ECONNRESET))
        #expect(frame.message == .text("xin chào"))
        #expect(frame.closure != nil && frame.closure?.code == nil)
        #expect(!frame.closedByPeer)
    }

    @Test("Messages keep the channel open; control frames deliver nothing; errors and end of stream end it")
    func others() {
        let binary = ReceivedFrame(opcode: .binary, closeCode: nil, data: Data([0x48, 0x4C]), isComplete: true,
                                   endOfStream: false, error: nil)
        #expect(binary.message == .binary(Data([0x48, 0x4C])) && binary.closure == nil)
        let pong = ReceivedFrame(opcode: .pong, closeCode: nil, data: nil, isComplete: true, endOfStream: false,
                                 error: nil)
        #expect(pong.message == nil && pong.closure == nil)
        let failed = ReceivedFrame(opcode: nil, closeCode: nil, data: nil, isComplete: false, endOfStream: false,
                                   error: .posix(.ENOTCONN))
        #expect(failed.message == nil && failed.closure?.code == nil && !failed.closedByPeer)
        let ended = ReceivedFrame(opcode: nil, closeCode: nil, data: nil, isComplete: true, endOfStream: true, error: nil)
        #expect(ended.closure?.detail == "end of stream")
    }
}
