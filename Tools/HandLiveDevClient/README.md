English | [Tiếng Việt](README.vi.md)

# HandLive Dev Client

A headless, development-only Mac client built from the real Apple packages — `HLProtocol`, `HLCrypto`,
`HLTransport`, `HLAppCore`, `HLSMS` and `HLCalls` — to test them against the real Android app running in an Android
emulator on the same Mac. It is not part of the apps, is not in the Xcode project, and builds with the Command Line
Tools alone. The Mac app itself needs Xcode and a signed build (keychain access groups, notifications, Focus), which a
command line tool does not have.

What runs is the apps' own code:

- **Pairing:** `PairingController` makes the PIN, `PairingSearch` and `PairingExchange` run PAIR-01 over the real
  `WebSocketConnector` (TLS 1.3, the certificate recorded and pinned). The tool types the PIN into the emulator.
- **Session:** `ConnectionManager` with the stored pair: the `/v1/ctl` handshake, capability exchange, keep-alive,
  `RECONNECT_BACKOFF`, sleep and wake.
- **Features:** `CallController` (call states, Answer, Decline, End with the one-`ack` rule), `CallLogEngine`
  (`log_sync`, `log_new`), `SmsEngine` (sync, `sms/new`, the outbox, `sms/status`), `ClipboardEngine` ("Send Clipboard
  to Phone"), fed with the link events as the Mac app model feeds them.

What is different from the app: keys live in files and settings in a plist in a scratch directory (no Keychain), the
clipboard is in memory, and there is no mDNS — the emulator's advertisement never reaches macOS — so the phone is
reached through `adb forward` at the pair's `last_host`/`last_port` (the connection manager's fast path).

## Build

```sh
cd apple/Tools/HandLiveDevClient
swift build                    # the Command Line Tools are enough; run ThirdParty/SQLCipher/fetch.sh once first
.build/out/Products/Debug/HandLiveDevClient --help   # or: swift run HandLiveDevClient …
```

## Run

The HandLive app runs in an emulator, set up once through its UI (first run, the SMS and call permissions through its
primers). Then:

```sh
C=.build/out/Products/Debug/HandLiveDevClient
S=~/tmp/handlive-devclient     # scratch: keys, settings, pair, database — never inside the repository
$C pair       --scratch $S --serial emulator-5554 --port 47830
$C status     --scratch $S
$C listen     --scratch $S --seconds 120
$C answer 0192f3f0 --scratch $S      # also reject, end; a call_id prefix as listen prints it
$C sms-send 5550105 "On my way" --scratch $S     # a number, or thread:<id> for a conversation
$C clip-push "Hello from the Mac" --scratch $S
$C log-sync   --scratch $S
$C demo       --scratch $S --lock ~/HandLive/.locks/emulator-5554
```

Every command sets up `adb -s <serial> forward tcp:<port> tcp:47800` first. Options: `--host` (127.0.0.1), `--port`
(47830), `--serial` (emulator-5554), `--adb` (`$ANDROID_HOME/platform-tools/adb`), `--name` (the name the phone shows,
"HandLive Dev Mac"), `--lock <dir>` (a lock directory shared with other users of the emulator, taken for `pair` and
`demo` and released on exit or Ctrl-C), `--step-delay <s>` (pause between UI steps, 1 s so a person can follow them in
the emulator window), `--seconds <n>` (`listen`).

- **`pair`** opens Devices › "Add Device" › "Enter PIN" on the phone, types the PIN this Mac shows, lets the search
  find the phone's PIN window, and compares the Security Code on both sides. With `--mac-timing` the window is visible
  to the search as soon as the phone opens it on "Enter PIN", which is when a real Mac sees TXT `pm = 1`; the phone
  then replaces the PIN field with "Pairing…" and the pairing cannot finish (see the Phase 3 report).
- **`listen`** prints each decoded `call_event/state`, `log_new`, `sms/new` and `sms/status` with its latency from
  the envelope `ts`.
- **`demo`** makes calls and SMS on the emulator's modem (`adb emu gsm call|accept|cancel`, `adb emu sms send`) with
  test numbers 5550101–5550105 and prints PASS or FAIL per step: ring → the Mac sees `ringing` → the Mac answers → the
  modem's call is active → the Mac ends it → `idle`; a second call the Mac declines; a missed call → `log_new`; an
  incoming SMS → `sms/new`; an SMS from the Mac → sent by the phone with `sms/status` moving forward; the Mac sleeps and
  wakes → the session comes back.

## Privacy

On the console, phone numbers keep only their last two digits and contact names their first letter; message texts are
never printed, only their length. Nothing is written into the repository: the tool refuses a scratch directory inside
the HandLive workspace.

## Limits

No UI: the call panel, notifications, the Focus rule, the menu bar, the Messages window and Settings need the real Mac
app. No relay (LAN through `adb forward` only), no call audio, no camera.
