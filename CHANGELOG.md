# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Calls from other apps on the Mac (CALL-05): decode `call_event/app_call`, the `features.call.app_calls` capability
  (the Mac reports `call.app_calls`, iPhone and iPad report `false`), `AppCallController` (latest version per
  `call_id`, Answer, Decline and End as `call_event/action`, `CALL_APP_ACTION_UNAVAILABLE`, `CALL_NOT_FOUND` and
  `FEATURE_DISABLED` handling), the call panel with the app's name, the tap-to-answer hint and "Audio: Phone", and the
  Calls from Other Apps checkbox in Settings › Calls.

### Changed

- CI (`ci-apple`): four parallel lanes (core tests, feature tests + Mac app, iOS app, SwiftLint + dev tools) instead
  of one serial job. `Tools/make-test-scheme.sh` writes a shared test scheme into `HandLive.xcworkspace`, so a lane
  builds the packages it tests once rather than once per package (2,869 compile units → 283 and 649); the Mac app
  reuses that build; the apps build for arm64 only; the DerivedData cache, which never avoided a rebuild, is gone.

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
