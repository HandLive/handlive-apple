# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Security

- Clipboard HTML: the sanitizer finds tags in linear time, so copying a large page no longer hangs the app. Repeated
  tag starts that never complete (`<a` without `>`, or before a quote that never closes) used to take quadratic time
  on the main thread that reads a copy, about 5 s for 80 KB on the Mac. The output is unchanged byte for byte
  (`clipboard-html.json`).

### Fixed

- Mac: Delete All HandLive Data also deletes the keys a build signed the other way left in the other keychain. After
  erasing in a team-signed build, the `ik_sig`, `ik_dh`, `db_key` and pair keys of an ad-hoc signed download are gone
  from the login keychain, whose items travel in Time Machine backups and through Migration Assistant (security scan
  of 2026-10-04, LOW). An ad-hoc build cannot reach the data-protection keychain, so a team build's device-only keys
  stay there until a team build erases; a fresh install still clears only its own keychain, so switching back finds
  the other build's keys (SET-02 API 7 logic 6, SET-03 API 1 logic 1).
- Mac, ad-hoc signed download: an updated build could not delete the keys the previous build created in the login
  keychain (`SecItemDelete` answered errSecInvalidOwnerEdit, -25244). Delete All left them, the next launch then
  stopped at the keychain error instead of starting setup, and Unpair kept the pair's key. `LoginKeychain` now finds
  them by reference and deletes them with `SecKeychainItemDelete`, without a dialog (0.6.1).

## [0.1.0-beta.2] — 2026-10-04

### Added

- Release workflow (`release-apple`): a pushed tag `v*`, or a manual run for an existing tag, attaches
  `HandLive-<version>-ios-unsigned.ipa` (Release build for devices with the Notification Service Extension, for
  sideloading) and the universal Mac app with their SHA-256 to the tag's GitHub Release:
  `HandLive-<version>-macos-unsigned.dmg` signed ad hoc, or, once the Developer ID and notarization secrets exist,
  `HandLive-<version>-macos.dmg` (signed inside out, hardened runtime, DMG notarized and stapled); the tag's version
  core must equal `MARKETING_VERSION`. Setup: hub `docs/deployment-guide.md`, Release builds.
- Mac builds without a team signature run: `KeychainSecretStore` picks the keychain from the app's own entitlements and
  falls back to the login keychain when the app has no keychain access group (an ad-hoc signed download), where the
  data-protection keychain answered every call with errSecMissingEntitlement (0.6.1). Delete All repeats the delete,
  since the login keychain removes one matching item per call.
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

- Settings on iPhone/iPad and the Mac: "Last synced" read "in 0 seconds" ("sau 0 giây nữa") right after a sync, since the
  numeric relative formatter prints any gap under a second that way. `HLRelativeTime` reads "now" under a minute (or for
  a future moment), as on Android.
- Mac and iPhone/iPad: a pair store or SMS database the current `db_key` cannot open (keys recreated after the Keychain
  lost them, or a build signed by another team) no longer leaves the app looking unpaired while every new pair fails to
  save and SMS stays off. `PairedDeviceStore.open` and `SmsDatabase.open` leave such a file where it is and use a
  second slot (`*.alt`), so switching back to the other build finds its data again; when both slots hold another
  key's file the older one gives way (one generation). Delete All removes both slots. The SQLCipher format is pinned
  with `PRAGMA cipher_compatibility = 4` (SET-03 API 1 logic 5).

### Security

- Release workflow: the signed Mac app is launched only after the signing keychain and the notary key are gone, in a
  step without secrets; the ad-hoc signed DMG is signed, launched and packed in the build job, which has no write
  access, so the release job runs no code of the repository while it holds the secrets.
- CI and the release workflow generate the Xcode project with XcodeGen 2.46.0 from its GitHub release, checked against
  its SHA-256 (`Tools/fetch-xcodegen.sh`), instead of Homebrew's current formula.

## [2026-09-30]

### Fixed

- LAN QR pairing on real devices: skip stale Bonjour `HL-*` ghosts, retry `PAIRING_CLOSED` without blacklisting
  the live phone, and store `lastHost` / `lastPort` after a successful pair for faster reconnect.
- Settings and Pair Phone windows stayed behind other apps (for example Cursor) while the menu-bar app was
  `.accessory`. The app now switches to `.regular`, activates, and floats those windows to the front.
- Permissions tab: Local Network status with Check Again.

### Changed

- Pairing search prefers any protocol `v=1` instance when no `pr` / `pm` TXT is visible yet.
