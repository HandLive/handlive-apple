# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [2026-09-30]

### Fixed

- LAN QR pairing on real devices: skip stale Bonjour `HL-*` ghosts, retry `PAIRING_CLOSED` without blacklisting
  the live phone, and store `lastHost` / `lastPort` after a successful pair for faster reconnect.
- Settings and Pair Phone windows stayed behind other apps (for example Cursor) while the menu-bar app was
  `.accessory`. The app now switches to `.regular`, activates, and floats those windows to the front.
- Permissions tab: Local Network status with Check Again.

### Changed

- Pairing search prefers any protocol `v=1` instance when no `pr` / `pm` TXT is visible yet.
