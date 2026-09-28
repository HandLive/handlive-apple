# Web spike (Mac, gate G6)

A development-only probe for Continue Browsing on the Mac (hub `plans/20260928-web-handoff/plan.md`, W4 and W8). It
answers, per browser and macOS version, before any WEB card is coded:

- Does Apple Events return the front window's active tab address and title for Safari, Chrome, Edge, Brave, Arc,
  Vivaldi and Opera? How long does one request take?
- Can a private window be told apart? Chromium browsers report the window `mode` (`normal` / `incognito`); Arc and
  Safari have no documented property, so the probe tries Arc's `incognito` and, for Safari, two probes (below).
- How does the Automation (TCC) permission behave: for a command-line tool, for an app bundle, with and without the
  hardened-runtime entitlement, with a Developer ID signature?

It logs `HLWEB` lines (the same shape as the Android spike): the browser, the **host only**, a salted hash of the
full address (salt random per install, in `~/Library/Application Support/HandLive Web Spike/salt`) and the title's
length. Full addresses and titles are never written. It sends nothing over the network. It is not part of the apps
and not part of CI.

## Build

```sh
cd apple/Tools/WebSpike
swift build -c release && swift test          # tests cover URL normalization, browser table, debounce, log lines
```

## Who gets the Automation permission

macOS asks for Automation per *responsible* app and per target browser ("X wants access to control Safari"):

- **Run from a terminal** (`.build/release/WebSpike …`): the responsible app is the terminal (Terminal, iTerm…), so
  the prompt and the entry in System Settings › Privacy & Security › Automation are the terminal's. The embedded
  `Info.plist` does not change that. Good enough to test what the browsers answer.
- **Run as an app** (`Support/make-app.sh`, then `open`): the prompt names "Web Spike" and shows its
  `NSAppleEventsUsageDescription`, as the HandLive app will. Needed for the W8 TCC question. An ad-hoc signature
  changes with every build, so TCC asks again after a rebuild; a Developer ID signature keeps the grant.
- **Hardened runtime** (required for notarization) blocks outgoing Apple Events unless the app has the entitlement
  `com.apple.security.automation.apple-events` (`Support/WebSpike.entitlements`). Expected without it: error `-1743`
  and no prompt — `NO_ENTITLEMENT=1 Support/make-app.sh` checks that.

```sh
Support/make-app.sh                                                    # ad-hoc, hardened runtime + entitlement
SIGN_IDENTITY="Developer ID Application: <name> (<team>)" Support/make-app.sh
open .build/WebSpike.app --args watch --log "$HOME/Desktop/hlweb-<macos>.log"
pkill -x WebSpike                                                      # stop it
```

To reset a decision between runs: `tccutil reset AppleEvents app.handlive.tools.web-spike` (or the terminal's
bundle id, e.g. `com.apple.Terminal`).

## Commands

| Command | What it does |
|---------|--------------|
| `permissions` | Automation state for each *running* browser (`granted`, `denied`, `not_determined`, `not_running`), without prompting |
| `ask <browser>` | Shows the Automation prompt for that browser now (only if not decided yet) |
| `once <browser>` | Reads the front window once: host, supported, private, `mode`, title length, time |
| `watch [--log FILE] [--interval 1.5]` | Follows the frontmost app; polls a supported browser every 1.5 s (`WEB_POLL_MAC`) and logs pages |
| `ax-dump [--delay 5] [--out FILE]` | Accessibility tree of the frontmost browser window outside the web content, values redacted |

`<browser>`: `safari`, `chrome`, `edge`, `brave`, `arc`, `vivaldi`, `opera`. Firefox has no URL scripting and is
not supported (W4).

## Log format

```
HLWEB ts=… ev=frontmost browser=chrome automation=granted status=0
HLWEB ts=… ev=active browser=chrome host=en.wikipedia.org hash=3fa1… private=false mode=normal title_len=24 script_ms=18.2
HLWEB ts=… ev=private browser=chrome private=true marker=mode:incognito script_ms=15.0
HLWEB ts=… ev=active browser=safari host=… hash=… private=unknown title_len=… script_ms=… bounds_match=yes ax=untrusted
HLWEB ts=… ev=inactive browser=chrome hash=3fa1… reason=deactivated|switched|locked|screen_sleep|sleep|session_inactive|unsupported|private|error
HLWEB ts=… ev=error browser=safari code=-1743 script_ms=3.1
HLWEB ts=… ev=stats polls=412 script_ms=6021.4 cpu_ms=880.2
```

- `active` once the address has been the same for 1.5 s (`WEB_SETTLE`); `private=unknown` means the product would
  not send.
- Error codes: `-1743` not allowed (Automation denied, or hardened runtime without the entitlement), `-1744` would
  need consent, `-1712` timeout, `-600` not running, `-1728` no such object (no window), `-2753` unknown property.
- `stats` every 5 minutes: polls, total time in Apple Events, the process's CPU time.

### Safari private windows (the open question)

Safari's dictionary has no private property. For each Safari page the probe logs:

- `bounds_match`: the scripted `front window` bounds against the frontmost on-screen Safari window
  (`CGWindowListCopyWindowInfo`). `no` would mean the window in front is invisible to scripting — what a private
  window hidden from Apple Events would look like — and is logged as `private` with marker `script_front_mismatch`.
- `ax`: when the process is trusted in Privacy & Security › Accessibility, the focused window's elements outside the
  web content are searched for "private" in a description, title or identifier (marker `ax:<role>/<attribute>`).
  Accessibility is a second permission the product would rather avoid; the spike measures whether it is needed.

Also run `ax-dump` in a normal and in a private Safari window and compare the two files.

## Test matrix (W8)

Macs: macOS 26 and macOS 13 (or 14); this Mac (macOS 27) as a third point. Browsers: Safari, Chrome, Arc
(required), Edge, Brave, Vivaldi, Opera (if installed). For each browser:

1. `permissions` with the browser running: note the state. Then `ask <browser>` (or let `watch` trigger the prompt):
   note the prompt's wording and which app it names.
2. `watch --log hlweb-<macos>.log`. In a **normal** window open `https://example.com`,
   `https://en.wikipedia.org/wiki/Handoff`, a page with a query; wait 3 s on each; switch tabs; open a new empty tab
   (expect `inactive reason=unsupported`); switch to another app (`reason=deactivated`); lock the screen (`locked`).
3. Same in a **private** window: expect `ev=private`, never `ev=active`. Safari: note `bounds_match` and `ax`, then
   repeat with the terminal trusted for Accessibility, and run `ax-dump` in both window kinds.
4. Deny Automation for one browser (System Settings › Privacy & Security › Automation): expect `ev=error code=-1743`.
5. App bundle: repeat step 1–2 for Safari and Chrome with `make-app.sh` ad-hoc, with `NO_ENTITLEMENT=1`, and with a
   Developer ID identity if available.

CPU: leave `watch` running for 30 minutes of normal browsing; note the last `stats` line and Activity Monitor's
"Energy Impact" of WebSpike (or the terminal) and of the browser, with and without `watch` running.

## Results to fill in

| macOS | Browser (version) | Mode | Automation prompt (who, wording) | `active` found | `private` right (`mode`/marker, `bounds_match`, `ax`) | `script_ms` typical | Errors | Go / no-go |
|-------|-------------------|------|----------------------------------|----------------|--------------------------------------------------------|---------------------|--------|------------|
| 27 | Safari | normal | | | | | | |
| 27 | Safari | private | | | | | | |
| 27 | Chrome | normal / incognito | | | | | | |
| 27 | Arc | normal / private | | | | | | |
| 26 | Safari | normal / private | | | | | | |
| 26 | Chrome | normal / incognito | | | | | | |
| 26 | Arc | normal / private | | | | | | |
| 13/14 | Safari | normal / private | | | | | | |
| 13/14 | Chrome | normal / incognito | | | | | | |
| 13/14 | Arc | normal / private | | | | | | |
| any | Edge, Brave, Vivaldi, Opera | normal / private | | | | | | |

| TCC case (Safari and Chrome) | Prompt shown? Names whom? | Result |
|------------------------------|---------------------------|--------|
| Terminal, CLI | | |
| App bundle, ad-hoc + entitlement | | |
| App bundle, hardened runtime without entitlement | | |
| App bundle, Developer ID + entitlement | | |
| After a rebuild (ad-hoc vs Developer ID) | | |

| Cost (30 min) | Value |
|---------------|-------|
| `stats`: polls / script_ms / cpu_ms | |
| Energy Impact WebSpike / browser (with, without) | |

Go for a browser: pages found on macOS 26 and 13/14, private windows never logged as `active`. Safari is a go only
if one probe detects private windows reliably without Accessibility, or the owner accepts the Accessibility
permission; otherwise Safari sends nothing (unknown → do not send) and the spec says so.
