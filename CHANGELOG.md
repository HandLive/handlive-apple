# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Release workflow (`release-apple`): a pushed tag `v*`, or a manual run for an existing tag, attaches
  `HandLive-<version>-ios-unsigned.ipa` (Release build for devices with the Notification Service Extension, for
  sideloading) and, once the Developer ID and notarization secrets exist, `HandLive-<version>-macos.zip` (universal,
  signed inside out, hardened runtime, notarized, stapled) with their SHA-256 to the tag's GitHub Release; the tag's
  version core must equal `MARKETING_VERSION`. Setup: hub `docs/deployment-guide.md`, Release builds.
- Calls from other apps on the Mac (CALL-05): decode `call_event/app_call`, the `features.call.app_calls` capability
  (the Mac reports `call.app_calls`, iPhone and iPad report `false`), `AppCallController` (latest version per
  `call_id`, Answer, Decline and End as `call_event/action`, `CALL_APP_ACTION_UNAVAILABLE`, `CALL_NOT_FOUND` and
  `FEATURE_DISABLED` handling), the call panel with the app's name, the tap-to-answer hint and "Audio: Phone", and the
  Calls from Other Apps checkbox in Settings › Calls.

### Changed

- CI (`ci-apple`): four parallel lanes (core tests, feature tests + Mac app, iOS app, tools) instead of one serial
  job, ~3 min instead of ~17. `Tools/make-test-scheme.sh` writes a shared test scheme into `HandLive.xcworkspace`, so
  a lane builds the packages it tests once rather than once per package (2,869 compile units → 283 and 649); the Mac
  app reuses that build; the DerivedData cache, which never avoided a rebuild, is gone. The tools lane keeps what the
  per-package builds used to guarantee: `Tools/check_package_imports.py` fails an import outside a target's declared
  dependencies, and the Mac app compiles once more for Intel (x86_64) beside the arm64 builds; it also runs SwiftLint
  and builds the dev tools. A pull request from a `main` or `feat/**` branch of this repository skips the macOS lanes,
  which the push run of the same commit already covers.

### Fixed

- Mac and iPhone/iPad: a pair store or SMS database the current `db_key` cannot open (keys recreated after the Keychain
  lost them, or a build signed by another team) no longer leaves the app looking unpaired while every new pair fails to
  save and SMS stays off. `PairedDeviceStore.open` and `SmsDatabase.open` leave such a file where it is and use a
  second slot (`*.alt`), so switching back to the other build finds its data again; when both slots hold another
  key's file the older one gives way (one generation). Delete All removes both slots. The SQLCipher format is pinned
  with `PRAGMA cipher_compatibility = 4` (SET-03 API 1 logic 5).

## [2026-09-30]

### Fixed

- LAN QR pairing on real devices: skip stale Bonjour `HL-*` ghosts, retry `PAIRING_CLOSED` without blacklisting
  the live phone, and store `lastHost` / `lastPort` after a successful pair for faster reconnect.
- Settings and Pair Phone windows stayed behind other apps (for example Cursor) while the menu-bar app was
  `.accessory`. The app now switches to `.regular`, activates, and floats those windows to the front.
- Permissions tab: Local Network status with Check Again.

### Changed

- Pairing search prefers any protocol `v=1` instance when no `pr` / `pm` TXT is visible yet.
