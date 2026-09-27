English | [Tiếng Việt](README.vi.md)

# HFP spike

A development-only probe that answers one question before any call-audio code is written: can macOS, in the
Bluetooth **hands-free (HF) role**, carry the audio of a cellular call from a paired Android phone, and how does it
expose that audio to apps (`07-call-audio.md` AUDIO-02)? It uses `IOBluetoothHandsFreeDevice`, prints one JSON object
per event, and never writes phone numbers or caller names. It is not part of the apps and builds with the Command
Line Tools alone.

## What you need

- A Mac (record its macOS version) and an Android phone with a SIM that can receive a call.
- The phone paired with the Mac in System Settings › Bluetooth, with call audio allowed for the Mac on the phone.
- A second phone to call from. Headphones on the Mac: the probe does not cancel echo.

## Run

```sh
cd apple/Tools/HFPSpike
swift build -c release
.build/release/HFPSpike list                          # find the phone: "hfp_gateway": true, note its address
.build/release/HFPSpike audio-devices                 # Core Audio devices before the test
.build/release/HFPSpike probe <address> --route --log hfp-<macos>-<phone>.jsonl
```

macOS may ask the terminal app for Bluetooth and microphone access the first time. In `probe`, type a command and
press Return:

| Command | What it does |
|---------|--------------|
| `a` / `e` | Answer / end the call |
| `c` / `p` | Move the call audio to the Mac (opens SCO) / back to the phone |
| `o` / `x` | Open / close the SCO link directly |
| `m` | Mute or unmute the Mac's microphone toward the phone |
| `h`, `l`, `d 123#` | Hold, list the calls, send DTMF |
| `s`, `q` | Show the state (indicators, features, SCO), quit |

With `--route`, when a new Core Audio device appears with the SCO link, the probe plays its input (the caller) on the
Mac's default output and sends the Mac's default microphone to its output (to the caller).

## A test call

1. Start `probe`; wait for `slc_connected` (service-level connection; `ms` is how long it took).
2. Call the phone from the second phone: expect `indicator` `callsetup = 1`, `incoming_call`, `ring`.
3. `a` to answer, then `c`: expect `sco_opened` (`ms` = time to open SCO) and `audio_devices_changed` with the device
   macOS created (name, transport, channels, sample rate: 8000 = CVSD, 16000 = mSBC).
4. Talk both ways and note what each side hears. Optional latency: clap near one phone and time it on the other.
5. Try `m`, `d 1`, `h`, `p` then `c` again, and `e`. Then `q`.
6. Repeat with AirPods connected to the Mac, and with the phone moving out of range.

## What to record

Per Mac (macOS version) and phone: service-level connection yes/no and time; the phone's features; SCO opened
yes/no and time; the audio device (name, transport, rate); heard both ways yes/no; rough latency; mute, DTMF, hold
results; errors (`unhandled_result`, `slc_disconnected` status). Keep the `.jsonl` logs with the report.
