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
    private struct QueuedFrame { let bytes: Data; let type: String?; let isLastOfMessage: Bool }

    private let bulkInflight: Int
    private var short: [Data] = []
    private var long: [QueuedFrame] = []
    private var bulk: [QueuedFrame] = []
    private var longBulkInflight = 0
    private var typesPendingLong: Set<String> = []

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

    /// Dữ liệu bulk trên kênh `0x02` (nội dung: 0.4.7, ngoài phạm vi thẻ này).
    public func enqueueBulk(_ data: Data) {
        bulk.append(contentsOf: fragment(type: nil, data: data, chan: BtLinkConstants.chanBulk, long: false))
    }

    public func hasPending() -> Bool { !short.isEmpty || !long.isEmpty || !bulk.isEmpty }

    /// Mảnh plaintext kế tiếp theo ưu tiên 0.4.5 "Priority", hay `nil` nếu không còn gì để gửi ngay.
    public func poll() -> Data? {
        if !short.isEmpty { return short.removeFirst() }
        guard longBulkInflight < bulkInflight else { return nil }
        if !long.isEmpty { return dispatch(long.removeFirst()) }
        if !bulk.isEmpty { return dispatch(bulk.removeFirst()) }
        return nil
    }

    /// Gọi khi một bản ghi dài/bulk đã `poll` trước đó thật sự xả khỏi bộ đệm ghi (mở lại một chỗ inflight).
    public func onDrained() {
        if longBulkInflight > 0 { longBulkInflight -= 1 }
    }

    private func dispatch(_ frame: QueuedFrame) -> Data {
        longBulkInflight += 1
        if frame.isLastOfMessage, let type = frame.type { typesPendingLong.remove(type) }
        return frame.bytes
    }

    private func fragment(type: String?, data: Data, chan: Int, long: Bool) -> [QueuedFrame] {
        let chunks = chunk(data, maxSize: BtLinkConstants.bulkFragmentMax)
        return chunks.enumerated().map { index, part in
            let more = index != chunks.count - 1
            let plaintext = BtTransportFrame.encode(chan: chan, more: more, long: long, data: part)
            return QueuedFrame(bytes: plaintext, type: type, isLastOfMessage: !more)
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
