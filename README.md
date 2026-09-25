English | [Tiếng Việt](README.vi.md)

# handlive-apple

The HandLive apps for Mac, iPhone and iPad, written in Swift 6 (macOS 13+, iOS 16+). The Mac app lives in the menu bar and handles the clipboard, SMS, call audio, and the phone's camera and microphone. iPhone and iPad receive the clipboard, SMS and call details. The UI is multilingual: English by default, Vietnamese as the second language (strings come from `../shared/strings`, detailed design 0.12).

Specification: `../docs/detailed-design/00-common-specs.md`. Plan: `../plans/20260925-implementation/` (hub repository).

This repository is one part of the HandLive workspace: the hub repository `handlive` (docs, plans) is the parent directory, and `../shared` is the `handlive-shared` repository (test vectors, schemas, design tokens). Clone the whole set from the hub with `tools/workspace.sh clone <group-url>`. See this repository's `CLAUDE.md`.

## Layout

| Path | Contents |
|------|----------|
| `project.yml` | XcodeGen: app target `HandLive` (menu bar, bundle `app.handlive.mac`) and 4 local packages. No signing configuration |
| `HandLive.xcworkspace` | Workspace referencing the generated `HandLive.xcodeproj` and the packages |
| `macOS/HandLive/` | Menu bar app (Phase 0 placeholder; features start in Phase 1) |
| `Packages/HLProtocol` | Envelope, `{op, data}`, Ack, `ErrorCode` (0.8.1), HL frames (0.5.2), binary `clipboard/chunk` plaintext, UUIDv7, b64/b64u, AAD, `session`/`capability` types |
| `Packages/HLCrypto` | Hand-written HChaCha20 + CryptoKit `ChaChaPoly` = XChaCha20-Poly1305; X25519, Ed25519, HKDF/HMAC-SHA256; `device_id`; PRK; handshake/rekey/`K_stream`; envelope and HL frame encryption; Keychain behind the `SecretStore` protocol |
| `Packages/HLTransport` | State machine 0.11, `RECONNECT_BACKOFF`, client-side handshake (pure logic; real networking from Phase 1) |
| `Packages/HLDesignSystem` | UI tokens (card M0.2) |

Dependencies: `HLTransport → HLCrypto → HLProtocol`.

## Generate the Xcode project

```sh
cd apple && xcodegen generate     # creates HandLive.xcodeproj (not committed, listed in .gitignore)
open HandLive.xcworkspace
```

## Tests

Tests use swift-testing (`import Testing`) and read `shared/test-vectors/*.json` and `shared/schemas/*.json` through paths relative to the workspace root (the parent directory holding `apple/`, `shared/` and the hub's `docs/`).

```sh
# With Xcode (CI): uses the Testing module bundled with Xcode
cd apple/Packages/HLCrypto && swift test
xcodebuild test -workspace apple/HandLive.xcworkspace -scheme HLCrypto -destination 'platform=macOS'

# Command Line Tools only: pulls the swift-testing package (release/6.2)
cd apple/Packages/HLCrypto && HL_SWIFT_TESTING_PACKAGE=1 swift test
```

Cross-platform vectors: `HL_WRITE_ROUNDTRIP=1` (in `HLCrypto`) rewrites `shared/test-vectors/envelope-roundtrip-apple.json`; regular test runs always decrypt that file and Android's `envelope-roundtrip.json` when present.

## Lint

```sh
cd apple && swiftlint lint --strict
# Command Line Tools only: TOOLCHAIN_DIR=/Library/Developer/CommandLineTools swiftlint lint --strict
```

## License

Apache License 2.0 — see [LICENSE](LICENSE); the bundled font keeps its own license, listed in [NOTICE](NOTICE). Contributions follow [CONTRIBUTING](https://github.com/HandLive/.github/blob/main/CONTRIBUTING.md) (small commits under a real name, DCO sign-off with `git commit -s`); report vulnerabilities privately as described in [SECURITY](https://github.com/HandLive/.github/blob/main/SECURITY.md).
