[English](README.md) | Tiếng Việt

# HandLive Dev Client

Một client Mac không giao diện, chỉ dùng khi phát triển, dựng từ chính các package Apple thật — `HLProtocol`,
`HLCrypto`, `HLTransport`, `HLAppCore`, `HLSMS` và `HLCalls` — để thử chúng với app Android thật chạy trong trình giả
lập Android trên cùng máy Mac. Nó không thuộc các app, không nằm trong dự án Xcode, và dựng được chỉ với Command Line
Tools. Bản thân app Mac cần Xcode và bản đã ký (keychain access group, thông báo, Tập trung), điều mà một công cụ dòng
lệnh không có.

Phần chạy là mã của chính các app:

- **Ghép nối:** `PairingController` tạo mã PIN, `PairingSearch` và `PairingExchange` chạy PAIR-01 qua
  `WebSocketConnector` thật (TLS 1.3, ghi lại và ghim chứng chỉ). Công cụ tự gõ mã PIN vào trình giả lập.
- **Phiên:** `ConnectionManager` với cặp đã lưu: bắt tay `/v1/ctl`, trao đổi capability, giữ kết nối,
  `RECONNECT_BACKOFF`, ngủ và thức.
- **Tính năng:** `CallController` (trạng thái cuộc gọi, Trả lời, Từ chối, Kết thúc theo quy tắc một lần chờ `ack`),
  `CallLogEngine` (`log_sync`, `log_new`), `SmsEngine` (đồng bộ, `sms/new`, hàng đợi gửi, `sms/status`),
  `ClipboardEngine` ("Gửi bảng nhớ tạm sang điện thoại"), nhận sự kiện kết nối như model của app Mac.

Khác với app: khóa nằm trong tệp và cài đặt nằm trong một plist ở thư mục nháp (không dùng Keychain), bảng nhớ tạm nằm
trong bộ nhớ, và không có mDNS — quảng bá của trình giả lập không tới được macOS — nên điện thoại được gọi qua
`adb forward` tại `last_host`/`last_port` của cặp (đường nhanh của bộ quản lý kết nối).

## Dựng

```sh
cd apple/Tools/HandLiveDevClient
swift build                    # chỉ cần Command Line Tools; chạy ThirdParty/SQLCipher/fetch.sh một lần trước
.build/out/Products/Debug/HandLiveDevClient --help   # hoặc: swift run HandLiveDevClient …
```

## Chạy

App HandLive chạy trong trình giả lập, đã thiết lập một lần qua giao diện của nó (lần chạy đầu, quyền SMS và cuộc gọi
qua các màn giới thiệu quyền). Sau đó:

```sh
C=.build/out/Products/Debug/HandLiveDevClient
S=~/tmp/handlive-devclient     # thư mục nháp: khóa, cài đặt, cặp, cơ sở dữ liệu — không bao giờ nằm trong kho mã
$C pair       --scratch $S --serial emulator-5554 --port 47830
$C status     --scratch $S
$C listen     --scratch $S --seconds 120
$C answer 0192f3f0 --scratch $S      # cả reject, end; phần đầu của call_id như listen in ra
$C sms-send 5550105 "Đang tới" --scratch $S     # một số điện thoại, hoặc thread:<id> cho một cuộc hội thoại
$C clip-push "Xin chào từ Mac" --scratch $S
$C log-sync   --scratch $S
$C demo       --scratch $S --lock ~/HandLive/.locks/emulator-5554
```

Lệnh nào cũng dựng `adb -s <serial> forward tcp:<port> tcp:47800` trước. Tùy chọn: `--host` (127.0.0.1), `--port`
(47830), `--serial` (emulator-5554), `--adb` (`$ANDROID_HOME/platform-tools/adb`), `--name` (tên điện thoại hiển
thị, "HandLive Dev Mac"), `--lock <dir>` (thư mục khóa dùng chung với những người khác dùng trình giả lập, giữ trong
`pair` và `demo`, trả lại khi thoát hoặc Ctrl-C), `--step-delay <s>` (khoảng dừng giữa các bước giao diện, 1 giây để
người xem theo kịp trong cửa sổ trình giả lập), `--seconds <n>` (`listen`).

- **`pair`** mở Thiết bị › "Add Device" › "Enter PIN" trên điện thoại, gõ mã PIN máy Mac này hiển thị, để phần tìm kiếm
  thấy cửa sổ PIN của điện thoại, và so sánh Mã bảo mật ở hai bên. Với `--mac-timing`, cửa sổ hiện ra với phần tìm
  kiếm ngay khi điện thoại mở nó lúc chạm "Enter PIN", đúng lúc một máy Mac thật thấy TXT `pm = 1`; khi đó điện thoại
  thay ô PIN bằng "Pairing…" và việc ghép nối không xong được (xem báo cáo Giai đoạn 3).
- **`listen`** in từng `call_event/state`, `log_new`, `sms/new` và `sms/status` đã giải mã kèm độ trễ tính từ `ts`
  của envelope.
- **`demo`** tạo cuộc gọi và SMS trên modem của trình giả lập (`adb emu gsm call|accept|cancel`, `adb emu sms send`)
  với các số thử 5550101–5550105 và in PASS hoặc FAIL cho từng bước: đổ chuông → Mac thấy `ringing` → Mac trả lời →
  cuộc gọi trên modem đang diễn ra → Mac kết thúc → `idle`; một cuộc gọi thứ hai Mac từ chối; một cuộc gọi nhỡ →
  `log_new`; một SMS đến → `sms/new`; một SMS từ Mac → điện thoại gửi đi, `sms/status` tiến lên; Mac ngủ rồi thức →
  phiên quay lại.

## Riêng tư

Trên màn hình dòng lệnh, số điện thoại chỉ giữ hai chữ số cuối và tên liên hệ chỉ giữ chữ cái đầu; nội dung tin nhắn
không bao giờ được in, chỉ in độ dài. Không có gì được ghi vào kho mã: công cụ từ chối thư mục nháp nằm trong workspace
HandLive.

## Giới hạn

Không có giao diện: panel cuộc gọi, thông báo, quy tắc Tập trung, menu trên thanh menu, cửa sổ Tin nhắn và Cài đặt cần
app Mac thật. Không có relay (chỉ mạng LAN qua `adb forward`), không có âm thanh cuộc gọi, không có camera.
