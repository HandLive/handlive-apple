English | [Tiếng Việt](README.vi.md)

# handlive-apple

The HandLive apps for Mac, iPhone and iPad, written in Swift 6 (macOS 13+, iOS 16+). The apps receive data from Android and send data back. The Mac app lives in the menu bar and handles the clipboard, SMS, call audio, and the phone camera and microphone. iPhone and iPad sync the clipboard, SMS and call details. The UI is multilingual: English by default, Vietnamese as the second language (strings come from `../shared/strings`, detailed design 0.12).

Specification: `../docs/detailed-design/00-common-specs.md`. Plan: `../plans/20260925-implementation/` (hub repository).

This repository is one part of the HandLive workspace: the hub repository `handlive` (docs, plans) is the parent directory, and `../shared` is the `handlive-shared` repository (test vectors, schemas, design tokens). Clone the whole set from the hub with `tools/workspace.sh clone <group-url>`. See this repository's `CLAUDE.md`.

## Layout

| Path | Contents |
|------|----------|
| `project.yml` | XcodeGen: app targets `HandLive` (Mac menu bar app, bundle `app.handlive.mac`), `HandLiveiOS` (iPhone and iPad, bundle `app.handlive.ios`) with `HandLiveNotificationService` (`app.handlive.ios.nse`), development language `en`, known regions `en` and `vi`, and the local packages. No signing configuration |
| `HandLive.xcworkspace` | Workspace referencing the generated `HandLive.xcodeproj` and the packages |
| `macOS/HandLive/` | Menu bar app entry point (`HandLiveMacApp`, app delegate); `Resources/Assets.xcassets` (AccentColor = `accent-fill`, generated), `Resources/InfoPlist.xcstrings` (purpose strings in en and vi, generated) |
| `macOS/Info.plist` | `NSBonjourServices`, `NSUserActivityTypes` (`INSendMessageIntent`, `INStartCallIntent`) and the English purpose strings, `NSFocusStatusUsageDescription` included (written by the string generator) |
| `macOS/HandLive.entitlements` | `keychain-access-groups` for the data-protection keychain, communication notifications (also what lets the app read the Focus status) and time-sensitive notifications (used once the app is signed; CI builds unsigned) |
| `iOS/HandLive/` | iPhone and iPad entry point (`HandLiveIOSApp` over `HLiOSUI`); `Resources/InfoPlist.xcstrings` (purpose strings) and `Resources/Localizable.xcstrings` (the `push.*` loc-keys of APNs alerts), both generated |
| `iOS/NotificationService/` | Notification Service Extension (CONN-04 step 9b): opens the push envelope with `K_push` while unlocked and builds the communication notification of a new SMS (`INSendMessageIntent`) or a ringing call (`INStartCallIntent`, "Decline"), or the missed-call notification; generic `loc-key` text otherwise |
| `iOS/Info.plist`, `iOS/NotificationService-Info.plist`, `iOS/*.entitlements` | Purpose strings (generated), `NSBonjourServices`, `NSUserActivityTypes` (`INSendMessageIntent`, `INStartCallIntent`) and the extension's `IntentsSupported`; `aps-environment`, communication and time-sensitive notifications, the App Group and keychain group `group.app.handlive` shared with the extension |
| `ThirdParty/GRDB` | GRDB.swift 7.11.1 (MIT) vendored with a manifest that builds it against SQLCipher (see its header) |
| `ThirdParty/SQLCipher` | Local package for the SQLCipher 4.19.0 XCFramework (BSD-style): run `ThirdParty/SQLCipher/fetch.sh` once after cloning — it downloads and checksum-verifies the framework (not committed) |
| `Packages/HLProtocol` | Envelope, `{op, data}`, Ack, `ErrorCode` (0.8.1), HL frames (0.5.2), binary `clipboard/chunk` plaintext, UUIDv7, b64/b64u, AAD, `session`/`capability` types |
| `Packages/HLCrypto` | Hand-written HChaCha20 + CryptoKit `ChaChaPoly` = XChaCha20-Poly1305; X25519, strict Ed25519, HKDF/HMAC-SHA256; BLAKE2b + Argon2id (`K_pin`); `device_id`; PRK; pairing MACs, `prk_check`, attestation; mDNS hints; handshake/rekey/`K_stream`; envelope and HL frame encryption; Keychain behind the `SecretStore` protocol |
| `Packages/HLTransport` | `ConnectionManager` (0.11 state machine, `last_host` fast path, mDNS discovery by hourly hint with `NWBrowser`, `NWPathMonitor`, `RECONNECT_BACKOFF`, sleep/wake, the relay route of CONN-03 with wake pushes), `WebSocketConnector` (TLS 1.3, certificate pinning, Network.framework WebSocket), the relay client (`RelayAPIClient` REST with `HLREG1`/`HLAUTH1` and JWT, SPKI-pinned `RelayTrust`, `RelayLink` over `/v1/relay`, pairing rendezvous), `ControlSession` (`/v1/ctl` handshake, capability, acks, de-duplication, rekey, keepalive, end-to-end ping and `session/bye` through the relay), close codes and the client's reaction, pairing (`PairingSearch` finds the phone's window by TXT `pr`/`pm` or meets it in the rendezvous, `PairingExchange` runs `/v1/pair`, `PairingInvite` builds the QR URI), `HLBENCH/1` debug logging. The relay host comes from the `HLRelayHost` Info.plist key (`HLRelayBackupPin` adds a backup SPKI pin); without it the apps stay on the LAN |
| `Packages/HLDesignSystem` | Colors (system APIs, hex only where the platform has none), text styles, metrics, `StatusIndicator`, `GroupedList`, button styles; `Scripts/generate-design-tokens.py` generates tokens from `../shared/design-tokens` |
| `Packages/HLAppCore` | Platform-neutral app state: settings keys (0.9.5), identity keys in the Keychain, this device's capability, the encrypted pair store (`paired_device`), the pairing controller (PAIR-01, QR code with relay rendezvous), permission helpers, the clipboard engine (`Clipboard/`: CLIP-01…05 — polling on the Mac, the Paste button on iPhone and iPad, inline and chunked transfers, conflicts, replay, auto-clear) behind a `ClipboardAccess` protocol, and the call controller (`Calls/`: CALL-01…03 — the phone's call applied in envelope order, Answer, Decline and End with one `ack` wait and the same envelope `id` on a new session, Decline from an iPhone notification; `AppCallController`, CALL-05 — calls from other apps on the phone, Mac only: `call_event/app_call` applied per `call_id`, Answer, Decline and End by the same `call_event/action`) |
| `Packages/HLSMS` | SMS (SMS-01…05): the SQLCipher database (`handlive.sqlite`, GRDB; it also holds the call log), the store, the engine (sync with cursors, history paging, `sms/new`, the outbox with the forward-only status rule, read state) and the GSM-7/UCS-2 part counter; `HLSMSNotifications` (no database): notification content, categories, removal rules, push decoding and de-duplication for the extension |
| `Packages/HLSMSUI` | The Messages screens shared by the Mac window and the iPhone/iPad tab: list, conversation, New Message, compose bar, display texts |
| `Packages/HLCalls` | Calls (CALL-01…04): `HLCalls` — the call log in the encrypted database (`call_log_entry`) and its engine (`log_sync` pages, `log_new`, missed calls, seen marks, 90-day pruning); `HLCallNotifications` (no database) — call notification content, categories and `userInfo`, removal rules, push decoding for the extension; `HLCallsUI` — the call list, display texts and the caller avatar |
| `Packages/HLMacUI` | The Mac app's model and views: `AppModel`, `AppCoordinator` (launch, reopen, sleep/wake, quit, Dock menu), menu bar menu and icon (with the ringing call and recent missed calls), the Messages window (with its Calls item), Settings panes (General with the relay actions, Devices, Clipboard, Messages, Calls with the quick replies), the welcome window (SET-03), the pairing sheet (PAIR-01), `MacPasteboard`, SMS, clipboard and call notifications, and the call panel (non-activating `NSPanel` on every Space, synthesized ringtone, Focus rule; the same panel shows a call from another app with its title, the tap-to-answer hint and "Audio: Phone") |
| `Packages/HLiOSUI` | The iPhone and iPad app: `IOSAppModel` (also built for macOS so its tests run with the Command Line Tools), setup (SET-03), the pairing sheet, the Clipboard (`PasteButton`), Messages (`NavigationSplitView`), Calls (the call log) and Settings tabs, the incoming-call banner, the app delegate (push token, SMS and call notification actions in background tasks); the views build for iOS only |
| `Tools/HandLiveDevClient` | Development only, not part of the apps: a headless Mac client built from the real packages (pairing by PIN, the `/v1/ctl` session, calls, SMS, clipboard, a scripted demo) to test them against the Android app in an emulator through `adb forward`; builds with the Command Line Tools (`swift build`), see its README |
| `Tools/CameraSpike` | Development only, not part of the apps: the gate G5 probe for Phase 5 — a Camera Extension with a sink stream fed by a host app, and a loopback HAL plug-in with its PKG; needs Xcode and XcodeGen (`./build.sh test`), not built in CI; the runbook for the owner is its README |
| `Packages/HLLocalization` | `Localizable.xcstrings` and type-safe `L10n` accessors generated from `../shared/strings/ui-strings.json` by `Scripts/generate-strings.py` (also the app's `InfoPlist.xcstrings` and Info.plist purpose strings); no UI text is written in code |

Dependencies: `HLTransport → HLCrypto → HLProtocol`; `HLDesignSystem → HLLocalization`; `HLAppCore → HLTransport`; `HLSMS → HLTransport, GRDB → SQLCipher`; `HLSMSUI → HLSMS, HLDesignSystem`; `HLCalls → HLAppCore, HLSMS, HLDesignSystem`; `HLMacUI`, `HLiOSUI → HLAppCore, HLSMSUI, HLCalls`.

After cloning, fetch SQLCipher once (CI does the same): `apple/ThirdParty/SQLCipher/fetch.sh`.

## Generated files

Both generators write committed files and have a `--check` mode that the package tests run:

```sh
python3 apple/Packages/HLDesignSystem/Scripts/generate-design-tokens.py   # tokens.json → colors, text styles, metrics
python3 apple/Packages/HLLocalization/Scripts/generate-strings.py        # ui-strings.json → String Catalogs, L10n
```

Change the catalog in `../shared` (docs first), then run the generator; never edit generated files by hand.

## Generate the Xcode project

```sh
cd apple && xcodegen generate     # creates HandLive.xcodeproj (not committed, listed in .gitignore)
# CI and releases use the pinned, checksum-verified XcodeGen: xcodegen="$(Tools/fetch-xcodegen.sh /tmp/xcodegen)"
open HandLive.xcworkspace
```

## Tests

Tests use swift-testing (`import Testing`) and read `shared/test-vectors/*.json` and `shared/schemas/*.json` through paths relative to the workspace root (the parent directory holding `apple/`, `shared/` and the hub's `docs/`).

```sh
# With Xcode: uses the Testing module bundled with Xcode
cd apple/Packages/HLCrypto && swift test
# Every package with one build of the shared ones (CI runs HLTests-core and HLTests-features in parallel lanes)
cd apple && Tools/make-test-scheme.sh HLTests-all all
xcodebuild test -workspace HandLive.xcworkspace -scheme HLTests-all -destination 'platform=macOS' -parallel-testing-enabled NO

# Command Line Tools only: pulls the swift-testing package (release/6.2) and uses the .lproj fallback of the
# String Catalogs. SwiftUI packages (HLDesignSystem, HLSMSUI, HLCalls, HLMacUI, HLiOSUI) need the macOS 26 SDK when a
# newer SDK is installed.
cd apple/Packages/HLCrypto && HL_SWIFT_TESTING_PACKAGE=1 swift test
cd apple/Packages/HLMacUI && HL_SWIFT_TESTING_PACKAGE=1 SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk swift test
```

The app targets build only with Xcode (CI: `xcodebuild build -scheme HandLive` for the Mac and `-scheme HandLiveiOS -destination 'generic/platform=iOS Simulator'` for iPhone and iPad with the extension, unsigned); everything they run lives in the packages.

Cross-platform vectors: `HL_WRITE_ROUNDTRIP=1` (in `HLCrypto`) rewrites `shared/test-vectors/envelope-roundtrip-apple.json`; regular test runs always decrypt that file and Android's `envelope-roundtrip.json` when present.

## Lint

```sh
cd apple && swiftlint lint --strict
# Command Line Tools only: TOOLCHAIN_DIR=/Library/Developer/CommandLineTools swiftlint lint --strict
```

## License

Apache License 2.0 — see [LICENSE](LICENSE); the bundled font keeps its own license, listed in [NOTICE](NOTICE). Contributions follow [CONTRIBUTING](https://github.com/HandLive/.github/blob/main/CONTRIBUTING.md) (small commits under a real name, DCO sign-off with `git commit -s`); report vulnerabilities privately as described in [SECURITY](https://github.com/HandLive/.github/blob/main/SECURITY.md).
