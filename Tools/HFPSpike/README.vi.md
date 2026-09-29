[English](README.md) | Tiếng Việt

# Spike HFP

Công cụ thăm dò chỉ dùng khi phát triển, trả lời một câu hỏi trước khi viết mã âm thanh cuộc gọi: macOS ở **vai trò
rảnh tay (HF)** của Bluetooth có mang được âm thanh cuộc gọi di động từ điện thoại Android đã ghép cặp không, và
macOS đưa âm thanh đó cho ứng dụng theo cách nào (`07-call-audio.md` AUDIO-02)? Công cụ dùng
`IOBluetoothHandsFreeDevice`, in mỗi sự kiện thành một đối tượng JSON và không bao giờ ghi số điện thoại hay tên người
gọi. Công cụ không thuộc ứng dụng và build được chỉ với Command Line Tools.

## Cần có

- Một máy Mac (ghi lại phiên bản macOS) và một điện thoại Android có SIM nhận được cuộc gọi.
- Điện thoại đã ghép cặp với Mac trong Cài đặt hệ thống › Bluetooth, và cho phép âm thanh cuộc gọi với Mac trên điện
  thoại.
- Một điện thoại thứ hai để gọi đến. Đeo tai nghe trên Mac: công cụ không khử tiếng vọng.

## Chạy

```sh
cd apple/Tools/HFPSpike
swift build -c release
.build/release/HFPSpike list                          # tìm điện thoại: "hfp_gateway": true, ghi lại địa chỉ
.build/release/HFPSpike audio-devices                 # các thiết bị Core Audio trước khi thử
.build/release/HFPSpike probe <địa chỉ> --route --log hfp-<macos>-<điện thoại>.jsonl
```

Lần đầu, macOS có thể hỏi quyền Bluetooth và micrô cho ứng dụng Terminal. Trong `probe`, gõ lệnh rồi nhấn Return:

| Lệnh | Tác dụng |
|------|----------|
| `a` / `e` | Trả lời / kết thúc cuộc gọi |
| `c` / `p` | Chuyển âm thanh cuộc gọi sang Mac (mở SCO) / về điện thoại |
| `o` / `x` | Mở / đóng trực tiếp liên kết SCO |
| `m` | Tắt hoặc bật micrô của Mac về phía điện thoại |
| `h`, `l`, `d 123#` | Giữ máy, liệt kê cuộc gọi, gửi DTMF |
| `s`, `q` | Xem trạng thái (chỉ báo, tính năng, SCO), thoát |

Với `--route`, khi một thiết bị Core Audio mới xuất hiện cùng liên kết SCO, công cụ phát đầu vào của thiết bị (người
gọi) ra đầu ra mặc định của Mac và gửi micrô mặc định của Mac vào đầu ra của thiết bị (tới người gọi).

## Một cuộc gọi thử

1. Chạy `probe`; chờ `slc_connected` (kết nối mức dịch vụ; `ms` là thời gian).
2. Gọi đến điện thoại từ máy thứ hai: sẽ có `indicator` `callsetup = 1`, `incoming_call`, `ring`.
3. `a` để trả lời, rồi `c`: sẽ có `sco_opened` (`ms` = thời gian mở SCO) và `audio_devices_changed` với thiết bị macOS
   tạo ra (tên, kiểu kết nối, số kênh, tần số lấy mẫu: 8000 = CVSD, 16000 = mSBC).
4. Nói chuyện hai chiều và ghi lại mỗi bên nghe thấy gì. Độ trễ (tùy chọn): vỗ tay gần một máy và bấm giờ ở máy kia.
5. Thử `m`, `d 1`, `h`, `p` rồi `c` lần nữa, và `e`. Sau đó `q`.
6. Lặp lại khi AirPods đang kết nối với Mac, và khi điện thoại ra khỏi vùng phủ sóng Bluetooth.

## Cần ghi lại

Cho mỗi máy Mac (phiên bản macOS) và điện thoại: có kết nối mức dịch vụ không và mất bao lâu; tính năng của điện
thoại; SCO có mở không và mất bao lâu; thiết bị âm thanh (tên, kiểu kết nối, tần số); hai bên có nghe nhau không; độ
trễ ước lượng; kết quả tắt micrô, DTMF, giữ máy; lỗi (`unhandled_result`, trạng thái `slc_disconnected`). Giữ các log
`.jsonl` cùng báo cáo.
