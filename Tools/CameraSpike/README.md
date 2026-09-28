English | [Tiếng Việt](README.vi.md)

# Camera spike (gate G5)

A development-only probe that answers the gate G5 questions before any Phase 5 code is written
(`plans/20260925-implementation/phase-05-camera-micro.md`, spike D6; `08-camera-mic.md` CAM-01, CAM-02; decisions
C8, C9, C11):

1. Can a Camera Extension (CMIOExtension), activated from an app in `/Applications`, deliver 720p30 frames pushed into
   its **sink** stream to FaceTime, Zoom, Meet and Photo Booth, and with what latency?
2. Does updating the extension need a restart (C11)?
3. Can an AudioServerPlugIn loopback — a hidden output device and a visible "microphone" sharing a ring buffer (C8) —
   installed by a PKG whose `postinstall` runs `killall coreaudiod` (C9), be heard in meeting apps?
4. What signing does each piece need?

It is not part of the apps, is not in `apple/project.yml`, and CI does not build it (CI lints its Swift files).

## What is in it

| Part | Path | What it does |
|------|------|--------------|
| Host app `HandLiveCameraSpike.app` (`app.handlive.spike.camera`) | `Host/` | Activates / inspects / deactivates the extension (`OSSystemExtensionRequest`); pushes a generated 1280×720 BGRA test pattern at 30 fps into the sink stream; camera self-check; microphone click track and self-check; big live clock; event log |
| Camera Extension (`app.handlive.spike.camera.extension`) | `Extension/` | Device "HandLive Camera Spike", UID `app.handlive.spike.camera.device`: a source stream (every client) and a sink stream (only signing ID `app.handlive.spike.camera`); forwards each sink frame at once with the current host time; a placeholder after 1 s without frames; Darwin notifications `app.handlive.spike.camera.demand` / `.idle` |
| HAL plug-in `HandLiveSpikeMic.driver` (`app.handlive.spike.mic`) | `AudioPlugin/` | Hidden output device "HandLive Microphone Spike Feed" (`app.handlive.spike.mic.feed`) and input device "HandLive Microphone Spike" (`app.handlive.spike.mic.input`), 48 kHz mono Float32, one shared ring buffer. Written from scratch against Apple's public `AudioServerPlugIn.h` — no BlackHole code (GPL-3.0) |
| PKG | `Packaging/`, `build.sh pkg` | `HandLiveSpikeMic.pkg` installs the plug-in into `/Library/Audio/Plug-Ins/HAL` (not relocatable), `postinstall` = `killall coreaudiod`; `HandLiveSpikeMic-Uninstall.pkg` removes it |
| Shared logic `CameraSpikeKit` | `Sources/`, `Tests/` | Test pattern with a millisecond clock and a 64-cell timestamp strip, frame clock, latency statistics, click track; Swift package with unit tests |

The test pattern: colour bars; a strip of 64 black/white cells across the top (the host-clock milliseconds + check
bits, read back by the self-check); the wall-clock time `HH:MM:SS.mmm` in large digits; a white box moving 8 px per
frame (jumps = dropped frames); the frame number. The placeholder is dark grey with `--:--`.

All identifiers differ from the product's (`app.handlive.camera.device`, `app.handlive.mic.*`), so the spike never
collides with a later HandLive install.

## Signing — read this first

| Piece | Needs | Why |
|-------|-------|-----|
| Host app | A provisioning profile that grants `com.apple.developer.system-extension.install` (the **System Extension** capability) | Restricted entitlement: without a profile the app is killed at launch, or the build fails |
| Camera Extension | Signed by the same team; app group `<TEAM>.app.handlive.spike.camera.extension` (its Mach service name must be inside it) | No profile needed for a team-prefixed app group on macOS (verified: it signs with Apple Development) |
| HAL plug-in | Any code signature; whether `coreaudiod` accepts Apple Development (and ad-hoc) is one of the checks below | `08-camera-mic.md` says ad-hoc is rejected; not verified yet |
| PKG | Unsigned works for a local test (Installer warns); product: "Developer ID Installer" + notarization (C9) | |

**On this Mac today:** the only identity is "Apple Development: me@hxd.vn (F349V24RRM)". F349V24RRM is the
certificate's ID, not a team: the certificate's team is **3S93UPADXV** ("Dung Ho"), and its only profile is an
Xcode-managed profile that lives 7 days — a free **Personal Team**. A Personal Team cannot add the System Extension
capability, so the host app cannot be signed until the owner joins the Apple Developer Program (paid). The extension
and the plug-in already sign with this identity.

**With a paid team** (expected, to confirm in the results):

- Development: Apple Development + a development profile with the System Extension capability that lists this Mac.
  The app must run from `/Applications`. SIP stays on. Notarization is not needed on a Mac listed in the profile.
- Distribution (the product, CAM-01): Developer ID Application for app, extension and plug-in, a Developer ID
  profile with the System Extension capability, notarization and stapling; the PKG signed with Developer ID
  Installer and notarized.
- Do **not** disable SIP or use `systemextensionsctl developer on` to work around signing: the result would not
  tell us what users will see.

## Build

Needs Xcode (tested with Xcode 27) and XcodeGen (`brew install xcodegen`). From `apple/Tools/CameraSpike`:

```sh
./build.sh test                           # unit tests + load the HAL plug-in in-process and check it (installs nothing)
./build.sh unsigned                       # compile check of everything (cannot be activated)
HL_ALLOW_PROVISIONING=1 ./build.sh dev <TEAM_ID>   # Apple Development; Xcode must be signed in to the team's account
./build.sh pkg                            # HandLiveSpikeMic.pkg + HandLiveSpikeMic-Uninstall.pkg from the last build
```

`HL_ALLOW_PROVISIONING=1` lets Xcode register the two bundle IDs, the app group and this Mac with the team and
download the profile (Xcode › Settings › Accounts must have the team). Products land in `.build/products/`.
`./build.sh developer-id <TEAM_ID>` archives, exports for Developer ID and notarizes (set `HL_NOTARY_PROFILE` from
`xcrun notarytool store-credentials`); `HL_INSTALLER_IDENTITY="Developer ID Installer: …" ./build.sh pkg` signs the
PKGs, then `xcrun notarytool submit .build/products/HandLiveSpikeMic.pkg --keychain-profile … --wait` and
`xcrun stapler staple` it.

## Run

Record the Mac model and macOS version for every run. Keep the event log: the window shows its path
(`~/Library/Logs/HandLiveCameraSpike/events-<time>.jsonl`, one JSON object per event). For both processes' system
logs: `log stream --predicate 'subsystem == "app.handlive.spike.camera"' --info`.

### A. Camera Extension

1. `ditto .build/products/HandLiveCameraSpike.app /Applications/HandLiveCameraSpike.app`, then open it from
   `/Applications`.
2. **Properties** (`extension_properties`: nothing installed yet), then **Activate**. Expect
   `extension_needs_approval`.
3. Approve: macOS 15 and later — System Settings › General › Login Items & Extensions › Camera Extensions, turn on
   "HandLive Camera Spike"; macOS 13–14 — System Settings › Privacy & Security, "System software from application
   HandLiveCameraSpike was blocked", **Allow**. Expect `extension_finished` `result: completed`.
   `systemextensionsctl list` shows the extension `[activated enabled]`.
4. **Start Feed**: expect `sink_opened` and `feeder_stats` every 5 s (`fps` ≈ 30, `queue_full` and `timer_skipped`
   near 0). A `feeder_failed` with a status means the sink could not be opened: note it (C11 — would the camera
   permission help? try again after **Start Self-Check** granted it).
5. Open **Photo Booth**, then **FaceTime** (Video › camera), **Zoom** (Settings › Video) and **Google Meet** in
   Safari and in Chrome; select "HandLive Camera Spike". The moving box must move smoothly and the clock run. The
   log shows `camera_demand` `…demand` when the first app starts the camera and `…idle` when the last stops.
6. **Latency, automatic:** **Start Self-Check** (allow camera access), wait 30 s, **Stop Self-Check**; read
   `selfcheck_latency_ms` (min/median/p95/max, frames, fps). This is host → extension → an AVFoundation client.
7. **Latency, as seen:** put the spike window's big clock next to the meeting app's self-view, take 5 screenshots
   (⇧⌘3), and for each subtract the clock shown in the video from the window's clock. Do it for each app.
8. **Stop Feed**: within about 1 s every app shows the grey `--:--` placeholder; **Start Feed** brings the pattern
   back.
9. **Sink guard:** in the system log, `sink start requested by … signingID=app.handlive.spike.camera allowed=true`.
   Any other signing ID must be refused.
10. **Update (C11):** quit the meeting apps, `HL_BUILD_NUMBER=2 HL_ALLOW_PROVISIONING=1 ./build.sh dev <TEAM_ID>`,
    replace the app in `/Applications`, open it, **Activate**. Expect `extension_replace` (1 → 2), then note
    `extension_finished` `completed` or `will_complete_after_reboot`, whether the camera works before a restart,
    and **Properties** before and after restarting the Mac.

### B. Microphone (HAL plug-in)

1. `./build.sh pkg`, then open `.build/products/HandLiveSpikeMic.pkg` (unsigned: Control-click › Open) and
   install. Sound on the Mac stops for about a second while `coreaudiod` restarts. Note the time from the end of
   Installer to the device appearing.
2. **Check Devices**: `mic_devices` shows `feed` with `hidden: 1` and `input` with `hidden: 0`. Audio MIDI Setup
   and System Settings › Sound › Input list only "HandLive Microphone Spike".
3. If the devices are missing: `log show --last 5m --predicate 'process == "coreaudiod"' | grep -i -E
   'HandLiveSpikeMic|plug-?in|sign'` and note the reason (e.g. a signature the daemon refuses).
4. **Start Clicks** (a 20 ms 1 kHz beep at every second into the hidden feed), then **Start Listening**: every 5
   beeps a `mic_loopback_latency_ms` line (feed → microphone inside the driver). **Stop Listening**.
5. With clicks running, select "HandLive Microphone Spike" in FaceTime, Zoom (Settings › Audio › Test Mic), Meet
   (Safari and Chrome) and QuickTime Player (New Audio Recording). The beeps must be heard/recorded once per second.
6. Check `running_somewhere` in **Check Devices** while a meeting app uses the microphone (it should become 1:
   CAM-02 trigger (b)).

### C. Uninstall

1. **Deactivate** (or drag the app from `/Applications` to the Bin: macOS offers to remove the extension); expect
   `extension_finished`; `systemextensionsctl list` no longer shows it enabled (note whether it needs a restart).
2. Open `HandLiveSpikeMic-Uninstall.pkg`; the devices disappear after `coreaudiod` restarts.
3. Delete the app, `~/Library/Logs/HandLiveCameraSpike` after copying the logs.

## Results to record

| # | Check | Result |
|---|-------|--------|
| 1 | Mac model, macOS version, Xcode version | |
| 2 | Team type (paid?) and whether `./build.sh dev` signs the host with the System Extension capability | |
| 3 | Activation from `/Applications` with Apple Development, SIP on: result and approval path in System Settings | |
| 4 | Activation from outside `/Applications` (run from `.build/products`): expected `unsupportedParentBundleLocation` | |
| 5 | Sink opened by the host (`sink_opened`); camera permission needed? | |
| 6 | Frames seen in Photo Booth / FaceTime / Zoom / Meet (Safari) / Meet (Chrome) | |
| 7 | Self-check latency ms (min / median / p95 / max) and fps | |
| 8 | Screenshot latency ms per app (5 samples each) | |
| 9 | Placeholder after Stop Feed within ~1 s | |
| 10 | `camera_demand` demand/idle notifications received | |
| 11 | Sink guard: signing ID seen, other clients refused | |
| 12 | Update 1 → 2: `completed` or `will_complete_after_reboot`; camera before restart; after restart | |
| 13 | PKG install: devices appear (time after Installer), feed hidden | |
| 14 | Plug-in signature accepted by `coreaudiod` (Apple Development; optionally ad-hoc: `codesign -f -s - …`) | |
| 15 | Loopback latency ms (`mic_loopback_latency_ms`) | |
| 16 | Clicks heard in FaceTime / Zoom / Meet (Safari) / Meet (Chrome) / QuickTime | |
| 17 | `running_somewhere` = 1 while a meeting app uses the microphone | |
| 18 | Deactivate and uninstall PKG: clean? restart needed? | |
| 19 | Errors (`extension_failed` name/code, `feeder_failed`, `mic_*_failed`) | |

Gate G5 passes when rows 3, 6 and 16 are yes with acceptable latency (CAM-02 targets < 120 ms end to end over
Wi-Fi, so the Mac-side share should be a small part of it). Otherwise Phase 5 stops and the report says why.
