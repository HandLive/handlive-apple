import Foundation
import HLProtocol
import Testing
@testable import HLTransport

/// 0.4.5 "Priority": ngắn > dài > bulk ở mỗi ranh giới mảnh; `BT_BULK_INFLIGHT` chỉ chặn dài+bulk, không chặn ngắn.
@Suite("Bluetooth link scheduler (0.4.5 Priority)")
struct BluetoothLinkSchedulerTests {
    @Test("short always polls before long and bulk")
    func shortAlwaysPollsBeforeLongAndBulk() throws {
        let scheduler = BluetoothLinkScheduler()
        scheduler.enqueueBulk(Data(count: 10))
        // "clipboard" vượt BT_FRAGMENT_MAX -> làn dài; "ping" nhỏ -> làn ngắn.
        scheduler.enqueueControlEnvelope(type: "clipboard", envelope: Data(count: BtLinkConstants.fragmentMax + 10))
        scheduler.enqueueControlEnvelope(type: "ping", envelope: Data(count: 5))
        let first = try #require(scheduler.poll())
        let frame = try BtTransportFrame.decode(first)
        #expect(frame.chan == BtLinkConstants.chanControl)
        #expect(frame.long == false)
        #expect(frame.data.count == 5)
    }

    @Test("long goes before bulk when no short is pending")
    func longGoesBeforeBulkWhenNoShortIsPending() throws {
        let scheduler = BluetoothLinkScheduler()
        scheduler.enqueueBulk(Data(count: 10))
        scheduler.enqueueControlEnvelope(type: "session", envelope: Data(count: 20)) // type "session" -> luôn làn dài
        let frame = try BtTransportFrame.decode(try #require(scheduler.poll()))
        #expect(frame.chan == BtLinkConstants.chanControl)
        #expect(frame.long == true)
    }

    @Test("the bulk-inflight cap never blocks a short envelope beyond that many records ahead")
    func bulkInflightCapNeverBlocksAShortEnvelope() throws {
        let scheduler = BluetoothLinkScheduler(bulkInflight: 2)
        scheduler.enqueueBulk(Data(count: 3000)) // 3 mảnh bulk
        _ = scheduler.poll() // mảnh 1 -> inflight = 1
        _ = scheduler.poll() // mảnh 2 -> inflight = 2 (chạm cận)
        #expect(scheduler.poll() == nil) // cận chặn mảnh 3 trong khi chưa có gì khác để gửi

        scheduler.enqueueControlEnvelope(type: "ping", envelope: Data(count: 5))
        // Ngắn không bị cận inflight chặn: tới ngay, sau tối đa BT_BULK_INFLIGHT mảnh dài/bulk đã gửi.
        let frame = try BtTransportFrame.decode(try #require(scheduler.poll()))
        #expect(frame.data.count == 5)
        #expect(frame.long == false)

        scheduler.onDrained()
        scheduler.onDrained()
        let third = try BtTransportFrame.decode(try #require(scheduler.poll()))
        #expect(third.chan == BtLinkConstants.chanBulk)
    }

    @Test("a short envelope overtakes a 256 KiB envelope already queued")
    func shortEnvelopeOvertakesA256KibEnvelopeAlreadyQueued() throws {
        let scheduler = BluetoothLinkScheduler(bulkInflight: 2)
        scheduler.enqueueControlEnvelope(type: "clipboard", envelope: Data(count: 256 * 1024))
        // Hai mảnh đầu của tin 256 KiB đã "gửi" (chiếm hết inflight), đúng như một liên kết thật đang bận.
        _ = scheduler.poll()
        _ = scheduler.poll()
        scheduler.enqueueControlEnvelope(type: "ping", envelope: Data(count: 5))
        let shortFrame = try BtTransportFrame.decode(try #require(scheduler.poll()))
        #expect(shortFrame.long == false)
        #expect(shortFrame.data.count == 5)
    }

    @Test("envelopes of the same type keep their send order")
    func sameTypeEnvelopesKeepTheirSendOrder() throws {
        let scheduler = BluetoothLinkScheduler(bulkInflight: 100)
        // A: vượt cận -> làn dài. B: cùng type, còn nhỏ nhưng A vẫn đang xếp hàng -> cũng làn dài. C: type khác.
        scheduler.enqueueControlEnvelope(type: "clipboard", envelope: Data(count: BtLinkConstants.fragmentMax + 10))
        scheduler.enqueueControlEnvelope(type: "clipboard", envelope: Data(count: 5))
        scheduler.enqueueControlEnvelope(type: "ping", envelope: Data(count: 5))

        var output: [Data] = []
        while let next = scheduler.poll() {
            output.append(next)
            scheduler.onDrained()
        }
        let frames = try output.map { try BtTransportFrame.decode($0) }

        // C (ping, type khác) đi làn ngắn, luôn trước mọi mảnh dài — không ảnh hưởng thứ tự A/B.
        #expect(frames.first?.long == false)
        #expect(frames.first?.data.count == 5)

        let longFrames = frames.filter { $0.long }
        #expect(longFrames.last?.data.count == 5, "B phải sau mọi mảnh của A")
        #expect(longFrames.filter { $0.data.count == 5 }.count == 1)
    }

    @Test("the session type always uses the long lane regardless of size")
    func sessionTypeAlwaysUsesTheLongLaneRegardlessOfSize() throws {
        let scheduler = BluetoothLinkScheduler()
        scheduler.enqueueControlEnvelope(type: "session", envelope: Data(count: 5))
        let frame = try BtTransportFrame.decode(try #require(scheduler.poll()))
        #expect(frame.long == true)
    }

    @Test("hasPending reflects all three queues")
    func hasPendingReflectsAllThreeQueues() {
        let scheduler = BluetoothLinkScheduler()
        #expect(scheduler.hasPending() == false)
        scheduler.enqueueBulk(Data(count: 1))
        #expect(scheduler.hasPending())
    }
}
