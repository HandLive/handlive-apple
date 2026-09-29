[English](README.md) | Tiếng Việt

# Spike camera (cổng G5)

Công cụ thử chỉ dùng khi phát triển, trả lời các câu hỏi của cổng G5 trước khi viết mã Phase 5
(`plans/20260925-implementation/phase-05-camera-micro.md`, spike D6; `08-camera-mic.md` CAM-01, CAM-02; quyết định
C8, C9, C11):

1. Một Camera Extension (CMIOExtension), kích hoạt từ app trong `/Applications`, có đưa được khung hình 720p30 mà app
   đẩy vào luồng **sink** tới FaceTime, Zoom, Meet và Photo Booth không, độ trễ bao nhiêu?
2. Cập nhật extension có cần khởi động lại máy không (C11)?
3. Một AudioServerPlugIn loopback — một thiết bị ra ẩn và một "micro" hiển thị dùng chung bộ đệm vòng (C8) — cài
   bằng PKG có `postinstall` chạy `killall coreaudiod` (C9), có nghe được trong app họp không?
4. Mỗi phần cần ký như thế nào?

Công cụ không thuộc app, không có trong `apple/project.yml`, CI không build nó (CI chỉ lint các tệp Swift).

## Thành phần

| Phần | Đường dẫn | Chức năng |
|------|-----------|-----------|
| App chủ `HandLiveCameraSpike.app` (`app.handlive.spike.camera`) | `Host/` | Kích hoạt / xem / hủy kích hoạt extension (`OSSystemExtensionRequest`); đẩy mẫu thử 1280×720 BGRA 30 fps vào luồng sink; tự kiểm camera; chuỗi tiếng bíp cho micro và tự kiểm; đồng hồ lớn; nhật ký sự kiện |
| Camera Extension (`app.handlive.spike.camera.extension`) | `Extension/` | Thiết bị "HandLive Camera Spike", UID `app.handlive.spike.camera.device`: luồng source (mọi client) và luồng sink (chỉ signing ID `app.handlive.spike.camera`); chuyển ngay mỗi khung từ sink với giờ máy hiện tại; khung chờ sau 1 s không có khung; thông báo Darwin `app.handlive.spike.camera.demand` / `.idle` |
| HAL plug-in `HandLiveSpikeMic.driver` (`app.handlive.spike.mic`) | `AudioPlugin/` | Thiết bị ra ẩn "HandLive Microphone Spike Feed" (`app.handlive.spike.mic.feed`) và thiết bị vào "HandLive Microphone Spike" (`app.handlive.spike.mic.input`), 48 kHz mono Float32, một bộ đệm vòng chung. Viết mới theo header công khai `AudioServerPlugIn.h` của Apple — không dùng mã BlackHole (GPL-3.0) |
| PKG | `Packaging/`, `build.sh pkg` | `HandLiveSpikeMic.pkg` cài plug-in vào `/Library/Audio/Plug-Ins/HAL` (không cho dời chỗ), `postinstall` = `killall coreaudiod`; `HandLiveSpikeMic-Uninstall.pkg` gỡ nó |
| Logic chung `CameraSpikeKit` | `Sources/`, `Tests/` | Mẫu thử có đồng hồ mili giây và dải 64 ô đánh dấu thời gian, đồng hồ khung, thống kê độ trễ, chuỗi bíp; package Swift có unit test |

Mẫu thử: các sọc màu; dải 64 ô đen/trắng ở mép trên (mili giây của đồng hồ máy + bit kiểm, phần tự kiểm đọc lại);
giờ `HH:MM:SS.mmm` chữ lớn; ô trắng chạy 8 px mỗi khung (giật = mất khung); số thứ tự khung. Khung chờ màu xám tối
với `--:--`.

Mọi định danh khác với sản phẩm (`app.handlive.camera.device`, `app.handlive.mic.*`) để spike không đụng bản
HandLive cài sau này.

## Ký — đọc trước

| Phần | Cần | Vì sao |
|------|-----|--------|
| App chủ | Provisioning profile cấp `com.apple.developer.system-extension.install` (capability **System Extension**) | Entitlement hạn chế: thiếu profile thì build lỗi hoặc app bị giết khi mở |
| Camera Extension | Ký cùng team; app group `<TEAM>.app.handlive.spike.camera.extension` (tên Mach service phải nằm trong nó) | macOS không cần profile cho app group có tiền tố team (đã kiểm: ký được bằng Apple Development) |
| HAL plug-in | Chữ ký bất kỳ; `coreaudiod` có nhận Apple Development (và ad-hoc) không là một mục cần kiểm bên dưới | `08-camera-mic.md` nói ad-hoc bị từ chối; chưa kiểm |
| PKG | Thử cục bộ thì không ký cũng được (Installer cảnh báo); sản phẩm: "Developer ID Installer" + notarization (C9) | |

**Trên máy này hiện nay:** danh tính duy nhất là "Apple Development: me@hxd.vn (F349V24RRM)". F349V24RRM là mã của
chứng chỉ, không phải team: team của chứng chỉ là **3S93UPADXV** ("Dung Ho"), và profile duy nhất do Xcode quản lý,
sống 7 ngày — một **Personal Team** miễn phí. Personal Team không thêm được capability System Extension, nên app chủ
chưa ký được cho tới khi chủ dự án tham gia Apple Developer Program (trả phí). Extension và plug-in đã ký được bằng
danh tính này.

**Với team trả phí** (dự kiến, cần xác nhận trong bảng kết quả):

- Phát triển: Apple Development + profile development có capability System Extension và có máy Mac này. App phải
  chạy từ `/Applications`. Giữ SIP bật. Không cần notarization trên máy có trong profile.
- Phát hành (sản phẩm, CAM-01): Developer ID Application cho app, extension và plug-in, profile Developer ID có
  capability System Extension, notarization và staple; PKG ký bằng Developer ID Installer và notarize.
- **Không** tắt SIP hay dùng `systemextensionsctl developer on` để lách việc ký: kết quả sẽ không cho biết người
  dùng thật gặp gì.

## Build

Cần Xcode (đã thử Xcode 27) và XcodeGen (`brew install xcodegen`). Trong `apple/Tools/CameraSpike`:

```sh
./build.sh test                           # unit test + nạp HAL plug-in ngay trong tiến trình và kiểm (không cài gì)
./build.sh unsigned                       # kiểm biên dịch mọi phần (không kích hoạt được)
HL_ALLOW_PROVISIONING=1 ./build.sh dev <TEAM_ID>   # Apple Development; Xcode phải đăng nhập tài khoản của team
./build.sh pkg                            # HandLiveSpikeMic.pkg + HandLiveSpikeMic-Uninstall.pkg từ lần build gần nhất
```

`HL_ALLOW_PROVISIONING=1` cho Xcode đăng ký hai bundle ID, app group và máy Mac này với team rồi tải profile (Xcode
› Settings › Accounts phải có team). Sản phẩm nằm ở `.build/products/`. `./build.sh developer-id <TEAM_ID>` archive,
xuất cho Developer ID và notarize (đặt `HL_NOTARY_PROFILE` từ `xcrun notarytool store-credentials`);
`HL_INSTALLER_IDENTITY="Developer ID Installer: …" ./build.sh pkg` ký các PKG, sau đó
`xcrun notarytool submit .build/products/HandLiveSpikeMic.pkg --keychain-profile … --wait` và `xcrun stapler staple`.

## Chạy

Ghi model Mac và phiên bản macOS cho mỗi lần chạy. Giữ nhật ký sự kiện: cửa sổ hiện đường dẫn
(`~/Library/Logs/HandLiveCameraSpike/events-<giờ>.jsonl`, mỗi dòng một đối tượng JSON). Log hệ thống của cả hai
tiến trình: `log stream --predicate 'subsystem == "app.handlive.spike.camera"' --info`.

### A. Camera Extension

1. `ditto .build/products/HandLiveCameraSpike.app /Applications/HandLiveCameraSpike.app`, rồi mở từ `/Applications`.
2. **Properties** (`extension_properties`: chưa cài gì), rồi **Activate**. Chờ `extension_needs_approval`.
3. Cho phép: macOS 15 trở lên — System Settings › General › Login Items & Extensions › Camera Extensions, bật
   "HandLive Camera Spike"; macOS 13–14 — System Settings › Privacy & Security, "System software from application
   HandLiveCameraSpike was blocked", **Allow**. Chờ `extension_finished` `result: completed`.
   `systemextensionsctl list` cho thấy extension `[activated enabled]`.
4. **Start Feed**: chờ `sink_opened` và `feeder_stats` mỗi 5 s (`fps` ≈ 30, `queue_full` và `timer_skipped` gần 0).
   `feeder_failed` kèm mã lỗi nghĩa là không mở được sink: ghi lại (C11 — quyền camera có giúp không? thử lại sau
   khi **Start Self-Check** đã xin quyền).
5. Mở **Photo Booth**, rồi **FaceTime** (Video › camera), **Zoom** (Settings › Video) và **Google Meet** trên Safari
   và Chrome; chọn "HandLive Camera Spike". Ô trắng phải chạy mượt, đồng hồ phải chạy. Nhật ký có `camera_demand`
   `…demand` khi app đầu tiên bật camera và `…idle` khi app cuối cùng tắt.
6. **Độ trễ, tự động:** **Start Self-Check** (cho phép camera), chờ 30 s, **Stop Self-Check**; đọc
   `selfcheck_latency_ms` (min/median/p95/max, frames, fps). Đây là app chủ → extension → một client AVFoundation.
7. **Độ trễ, mắt thấy:** đặt đồng hồ lớn của cửa sổ spike cạnh khung tự xem của app họp, chụp 5 ảnh màn hình (⇧⌘3),
   mỗi ảnh lấy giờ của cửa sổ trừ giờ hiện trong video. Làm cho từng app.
8. **Stop Feed**: trong khoảng 1 s mọi app hiện khung chờ xám `--:--`; **Start Feed** đưa mẫu thử trở lại.
9. **Chặn sink:** trong log hệ thống có `sink start requested by … signingID=app.handlive.spike.camera allowed=true`.
   Signing ID khác phải bị từ chối.
10. **Cập nhật (C11):** thoát các app họp, `HL_BUILD_NUMBER=2 HL_ALLOW_PROVISIONING=1 ./build.sh dev <TEAM_ID>`, thay
    app trong `/Applications`, mở, **Activate**. Chờ `extension_replace` (1 → 2), ghi `extension_finished`
    `completed` hay `will_complete_after_reboot`, camera có chạy trước khi khởi động lại không, và **Properties**
    trước và sau khi khởi động lại Mac.

### B. Micro (HAL plug-in)

1. `./build.sh pkg`, mở `.build/products/HandLiveSpikeMic.pkg` (chưa ký: Control-click › Open) và cài. Âm thanh trên
   Mac tắt khoảng một giây khi `coreaudiod` khởi động lại. Ghi thời gian từ lúc Installer xong tới lúc thiết bị hiện.
2. **Check Devices**: `mic_devices` có `feed` với `hidden: 1` và `input` với `hidden: 0`. Audio MIDI Setup và System
   Settings › Sound › Input chỉ liệt kê "HandLive Microphone Spike".
3. Nếu thiếu thiết bị: `log show --last 5m --predicate 'process == "coreaudiod"' | grep -i -E
   'HandLiveSpikeMic|plug-?in|sign'` và ghi lý do (ví dụ chữ ký bị daemon từ chối).
4. **Start Clicks** (tiếng bíp 1 kHz dài 20 ms mỗi giây vào thiết bị feed ẩn), rồi **Start Listening**: mỗi 5 tiếng
   bíp có một dòng `mic_loopback_latency_ms` (feed → micro bên trong driver). **Stop Listening**.
5. Khi đang phát bíp, chọn "HandLive Microphone Spike" trong FaceTime, Zoom (Settings › Audio › Test Mic), Meet
   (Safari và Chrome) và QuickTime Player (New Audio Recording). Phải nghe/thu được mỗi giây một tiếng bíp.
6. Xem `running_somewhere` trong **Check Devices** khi app họp đang dùng micro (phải thành 1: kích hoạt (b) của
   CAM-02).

### C. Gỡ

1. **Deactivate** (hoặc kéo app từ `/Applications` vào Thùng rác: macOS đề nghị xóa extension); chờ
   `extension_finished`; `systemextensionsctl list` không còn thấy nó bật (ghi có cần khởi động lại không).
2. Mở `HandLiveSpikeMic-Uninstall.pkg`; thiết bị biến mất sau khi `coreaudiod` khởi động lại.
3. Xóa app, và `~/Library/Logs/HandLiveCameraSpike` sau khi đã chép nhật ký.

## Kết quả cần ghi

| # | Mục kiểm | Kết quả |
|---|----------|---------|
| 1 | Model Mac, phiên bản macOS, phiên bản Xcode | |
| 2 | Loại team (trả phí?) và `./build.sh dev` có ký được app chủ với capability System Extension không | |
| 3 | Kích hoạt từ `/Applications` bằng Apple Development, SIP bật: kết quả và đường cho phép trong System Settings | |
| 4 | Kích hoạt từ ngoài `/Applications` (chạy từ `.build/products`): dự kiến `unsupportedParentBundleLocation` | |
| 5 | App chủ mở được sink (`sink_opened`); có cần quyền camera không? | |
| 6 | Thấy khung hình trong Photo Booth / FaceTime / Zoom / Meet (Safari) / Meet (Chrome) | |
| 7 | Độ trễ tự kiểm ms (min / median / p95 / max) và fps | |
| 8 | Độ trễ qua ảnh chụp màn hình ms theo từng app (5 mẫu mỗi app) | |
| 9 | Khung chờ sau Stop Feed trong ~1 s | |
| 10 | Nhận được thông báo `camera_demand` demand/idle | |
| 11 | Chặn sink: signing ID thấy được, client khác bị từ chối | |
| 12 | Cập nhật 1 → 2: `completed` hay `will_complete_after_reboot`; camera trước khi khởi động lại; sau khi khởi động lại | |
| 13 | Cài PKG: thiết bị hiện (bao lâu sau Installer), feed ẩn | |
| 14 | `coreaudiod` nhận chữ ký plug-in (Apple Development; tùy chọn ad-hoc: `codesign -f -s - …`) | |
| 15 | Độ trễ loopback ms (`mic_loopback_latency_ms`) | |
| 16 | Nghe tiếng bíp trong FaceTime / Zoom / Meet (Safari) / Meet (Chrome) / QuickTime | |
| 17 | `running_somewhere` = 1 khi app họp dùng micro | |
| 18 | Deactivate và PKG gỡ: sạch không? cần khởi động lại không? | |
| 19 | Lỗi (`extension_failed` name/code, `feeder_failed`, `mic_*_failed`) | |

Cổng G5 đạt khi các dòng 3, 6 và 16 là có, với độ trễ chấp nhận được (CAM-02 đặt mục tiêu < 120 ms đầu-cuối qua
Wi-Fi, nên phần trên Mac chỉ nên chiếm một phần nhỏ). Nếu không, Phase 5 dừng và báo cáo nêu lý do.
