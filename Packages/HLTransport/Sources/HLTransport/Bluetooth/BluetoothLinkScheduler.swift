import Foundation
import HLProtocol

/// Bộ lập lịch gửi của một liên kết Bluetooth (0.4.5 "Priority"): ba hàng đợi, ở mỗi ranh giới mảnh `poll` trả
/// mảnh từ hàng đợi không rỗng đầu tiên theo thứ tự ngắn, dài, bulk. Tối đa `bulkInflight` bản ghi dài+bulk đã
/// gửi (đã `poll`) mà chưa xả (gọi `onDrained`) cùng lúc; làn ngắn không bị giới hạn này nên luôn tới ngay sau
/// mảnh đang gửi, không phải chờ thêm mảnh dài/bulk nào khác xếp sau nó.
///
/// Một phong bì cùng `type` với một tin làn dài còn đang xếp hàng/trên đường gửi phải đi làn dài theo sau nó
/// (0.4.5 "Order"): `typesPendingLong` theo dõi điều này, xoá khi mảnh CUỐI của tin đó được `poll` — thứ tự trên
/// dây đã chốt ngay lúc đó vì liên kết chỉ có một luồng byte nối tiếp.
public final class BluetoothLinkScheduler {
    private struct QueuedFrame { let bytes: Data; let type: String?; let isLastOfMessage: Bool; let isLastOfBulkEnvelope: Bool }

    private let bulkInflight: Int
    private var short: [Data] = []
    private var long: [QueuedFrame] = []
    private var bulk: [QueuedFrame] = []
    private var longBulkInflight = 0
    private var typesPendingLong: Set<String> = []
    /// Số phong bì bulk đã xếp hàng mà chưa ghi xong (0.4.7 bulk rule 4): `send(.bulkText)` chặn khi đạt
    /// `BT_BULK_QUEUED`. Tăng khi `enqueueBulk`, giảm khi mảnh cuối của phong bì được `onBulkEnvelopeDrained`.
    private var bulkEnvelopesQueued = 0

    public init(bulkInflight: Int = BluetoothLinkConstants.bulkInflight) {
        self.bulkInflight = bulkInflight
    }

    /// Phong bì JSON (0.5.1) trên kênh điều khiển `0x01`; tự chọn làn ngắn hay dài theo 0.4.5 "Control channel".
    public func enqueueControlEnvelope(type: String, envelope: Data) {
        let mustUseLong = envelope.count > BtLinkConstants.fragmentMax || type == MessageType.session.rawValue
            || typesPendingLong.contains(type)
        if mustUseLong {
            typesPendingLong.insert(type)
            long.append(contentsOf: fragment(type: type, data: envelope, chan: BtLinkConstants.chanControl, long: true))
        } else {
            short.append(BtTransportFrame.encode(chan: BtLinkConstants.chanControl, more: false, long: false, data: envelope))
        }
    }

    /// Một phong bì bulk (0.4.7) trên kênh `0x02`: UTF-8, cùng byte với WS text frame trên `/v1/ctl`. Tăng
    /// `bulkEnvelopesQueued`; bên gọi chặn khi đạt `BT_BULK_QUEUED` (rule 4).
    public func enqueueBulk(_ data: Data) {
        bulk.append(contentsOf: fragment(type: nil, data: data, chan: BtLinkConstants.chanBulk, long: false))
        bulkEnvelopesQueued += 1
    }

    /// Số phong bì bulk đang xếp hàng mà chưa ghi xong (0.4.7 bulk rule 4).
    public var pendingBulkEnvelopes: Int { bulkEnvelopesQueued }

    public func hasPending() -> Bool { !short.isEmpty || !long.isEmpty || !bulk.isEmpty }

    /// Mảnh plaintext kế tiếp theo ưu tiên 0.4.5 "Priority", hay `nil` nếu không còn gì để gửi ngay.
    /// `isLastOfBulkEnvelope` = `true` khi mảnh này là mảnh cuối của một phong bì bulk (0.4.7 bulk rule 4):
    /// bên gọi gọi `onBulkEnvelopeDrained` khi mảnh đó thật sự xả khỏi bộ đệm ghi.
    public func poll() -> (data: Data, isLastOfBulkEnvelope: Bool)? {
        if !short.isEmpty { return (short.removeFirst(), false) }
        guard longBulkInflight < bulkInflight else { return nil }
        if !long.isEmpty {
            let frame = long.removeFirst()
            return (dispatch(frame), false)
        }
        if !bulk.isEmpty {
            let frame = bulk.removeFirst()
            return (dispatch(frame), frame.isLastOfBulkEnvelope)
        }
        return nil
    }

    /// Gọi khi một bản ghi dài/bulk đã `poll` trước đó thật sự xả khỏi bộ đệm ghi (mở lại một chỗ inflight).
    public func onDrained() {
        if longBulkInflight > 0 { longBulkInflight -= 1 }
    }

    /// Gọi khi mảnh cuối của một phong bì bulk đã xả khỏi bộ đệm ghi (giảm `bulkEnvelopesQueued`).
    public func onBulkEnvelopeDrained() {
        if bulkEnvelopesQueued > 0 { bulkEnvelopesQueued -= 1 }
    }

    private func dispatch(_ frame: QueuedFrame) -> Data {
        longBulkInflight += 1
        if frame.isLastOfMessage, let type = frame.type { typesPendingLong.remove(type) }
        return frame.bytes
    }

    private func fragment(type: String?, data: Data, chan: Int, long: Bool) -> [QueuedFrame] {
        let chunks = chunk(data, maxSize: BtLinkConstants.bulkFragmentMax)
        let isBulk = chan == BtLinkConstants.chanBulk
        return chunks.enumerated().map { index, part in
            let more = index != chunks.count - 1
            let plaintext = BtTransportFrame.encode(chan: chan, more: more, long: long, data: part)
            return QueuedFrame(bytes: plaintext, type: type, isLastOfMessage: !more,
                               isLastOfBulkEnvelope: isBulk && !more)
        }
    }

    private func chunk(_ data: Data, maxSize: Int) -> [Data] {
        if data.isEmpty { return [Data()] }
        var out: [Data] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: maxSize, limitedBy: data.endIndex) ?? data.endIndex
            out.append(data.subdata(in: offset..<end))
            offset = end
        }
        return out
    }
}
