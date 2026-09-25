[English](README.md) | Tiếng Việt

# handlive-apple

Ứng dụng cho Mac, iPhone và iPad, viết bằng Swift 6 (macOS 13+, iOS 16+). Mac có app trên thanh menu, đủ clipboard, SMS, âm thanh cuộc gọi, camera và mic. iPhone và iPad nhận clipboard, SMS và thông tin cuộc gọi. Giao diện đa ngôn ngữ: tiếng Anh mặc định, tiếng Việt là ngôn ngữ thứ hai (chuỗi từ `../shared/strings`, thiết kế chi tiết 0.12).

Đặc tả: `../docs/detailed-design/00-common-specs.md`. Kế hoạch: `../plans/20260925-implementation/` (kho hub).

Kho này là một phần của workspace HandLive: kho hub `handlive` (tài liệu, kế hoạch) là thư mục cha, `../shared` là kho `handlive-shared` (test vector, schema, design tokens). Clone cả bộ từ hub: `tools/workspace.sh clone <group-url>`. Xem `CLAUDE.md` của kho này.

## Bố cục

| Đường dẫn | Nội dung |
|-----------|----------|
| `project.yml` | XcodeGen: target app `HandLive` (menu bar, bundle `app.handlive.mac`, ngôn ngữ phát triển `en`, vùng `en` và `vi`) và các local package. Không cấu hình ký |
| `HandLive.xcworkspace` | Workspace tham chiếu `HandLive.xcodeproj` (sinh ra) và các package |
| `macOS/HandLive/` | App menu bar; `Resources/Assets.xcassets` (AccentColor = `accent-fill`, sinh ra), `Resources/InfoPlist.xcstrings` (purpose string tiếng Anh và tiếng Việt, sinh ra) |
| `macOS/Info.plist` | `NSBonjourServices` và purpose string tiếng Anh (bộ sinh chuỗi ghi) |
| `Packages/HLProtocol` | Envelope, `{op, data}`, Ack, `ErrorCode` (0.8.1), khung HL (0.5.2), plaintext nhị phân `clipboard/chunk`, UUIDv7, b64/b64u, AAD, kiểu `session`/`capability` |
| `Packages/HLCrypto` | HChaCha20 tự cài + CryptoKit `ChaChaPoly` = XChaCha20-Poly1305; X25519, Ed25519, HKDF/HMAC-SHA256; `device_id`; PRK; bắt tay/rekey/`K_stream`; mã hóa envelope và khung HL; Keychain sau protocol `SecretStore` |
| `Packages/HLTransport` | Máy trạng thái 0.11 cùng các cạnh lỗi, `RECONNECT_BACKOFF`, mã đóng và phản ứng của client, bắt tay phía client |
| `Packages/HLDesignSystem` | Màu (API hệ thống, hex chỉ khi nền tảng không có API), kiểu chữ, số đo, `StatusIndicator`, `GroupedList`, kiểu nút; `Scripts/generate-design-tokens.py` sinh token từ `../shared/design-tokens` |
| `Packages/HLLocalization` | `Localizable.xcstrings` và accessor `L10n` an toàn kiểu, sinh từ `../shared/strings/ui-strings.json` bằng `Scripts/generate-strings.py` (kèm `InfoPlist.xcstrings` và purpose string trong Info.plist của app); mã không viết câu chữ giao diện |

Phụ thuộc: `HLTransport → HLCrypto → HLProtocol`; `HLDesignSystem → HLLocalization`.

## File sinh ra

Hai bộ sinh ghi file được commit và có chế độ `--check` mà test của package chạy:

```sh
python3 apple/Packages/HLDesignSystem/Scripts/generate-design-tokens.py   # tokens.json → màu, kiểu chữ, số đo
python3 apple/Packages/HLLocalization/Scripts/generate-strings.py        # ui-strings.json → String Catalog, L10n
```

Sửa catalog trong `../shared` (tài liệu trước), rồi chạy bộ sinh; không sửa tay file sinh ra.

## Sinh project Xcode

```sh
cd apple && xcodegen generate     # tạo HandLive.xcodeproj (không commit, đã có trong .gitignore)
open HandLive.xcworkspace
```

## Test

Test dùng swift-testing (`import Testing`) và đọc thẳng `shared/test-vectors/*.json`, `shared/schemas/*.json` theo đường dẫn tương đối tới gốc workspace (thư mục cha chứa `apple/`, `shared/` và `docs/` của kho hub).

```sh
# Có Xcode (CI): dùng Testing đi kèm Xcode
cd apple/Packages/HLCrypto && swift test
xcodebuild test -workspace apple/HandLive.xcworkspace -scheme HLCrypto -destination 'platform=macOS'

# Chỉ có Command Line Tools: kéo gói swift-testing (release/6.2)
cd apple/Packages/HLCrypto && HL_SWIFT_TESTING_PACKAGE=1 swift test
```

Vector liên nền tảng: `HL_WRITE_ROUNDTRIP=1` (trong `HLCrypto`) ghi lại `shared/test-vectors/envelope-roundtrip-apple.json`; test thường luôn giải mã file đó và `envelope-roundtrip.json` của Android nếu có.

## Lint

```sh
cd apple && swiftlint lint --strict
# chỉ có Command Line Tools: TOOLCHAIN_DIR=/Library/Developer/CommandLineTools swiftlint lint --strict
```

## Giấy phép

Apache License 2.0 — xem [LICENSE](LICENSE); font đóng gói theo giấy phép riêng ghi trong [NOTICE](NOTICE). Đóng góp theo [CONTRIBUTING](https://github.com/HandLive/.github/blob/main/CONTRIBUTING.vi.md) (commit nhỏ, đứng tên người thật, ký DCO bằng `git commit -s`); báo lỗi bảo mật kín theo [SECURITY](https://github.com/HandLive/.github/blob/main/SECURITY.vi.md).
