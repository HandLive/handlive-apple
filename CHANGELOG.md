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

## [2026-09-30]

### Fixed

- LAN QR pairing on real devices: skip stale Bonjour `HL-*` ghosts, retry `PAIRING_CLOSED` without blacklisting
  the live phone, and store `lastHost` / `lastPort` after a successful pair for faster reconnect.
- Settings and Pair Phone windows stayed behind other apps (for example Cursor) while the menu-bar app was
  `.accessory`. The app now switches to `.regular`, activates, and floats those windows to the front.
- Permissions tab: Local Network status with Check Again.

### Changed

- Pairing search prefers any protocol `v=1` instance when no `pr` / `pm` TXT is visible yet.
