# Pult — Mac host

Control your Mac from your iPhone with low latency, straight device-to-device.
This repository is the **Mac host**: a tiny menu-bar app that streams the
screen and applies the phone's touch, keyboard and gamepad input. The iPhone
app, **Pult**, is on the App Store.

- Peer-to-peer H.264 over one TCP connection, hardware-encoded, no server in
  between.
- At home it's found automatically over Bonjour. Away from home it goes over
  one TLS port you forward on your router, with a 256-bit key the phone
  receives automatically the first time it connects at home.
- The cursor is drawn on the phone, so pointer motion has no network lag.
- Screen, keyboard, trackpad, a gamepad overlay, voice dictation, paste, and
  waking/unlocking the Mac.

## Download

Get the latest signed, notarized build from the
[releases page](https://github.com/Hadevs/pult-host/releases/latest), or the
[Pult website](https://pult.209-74-79-242.sslip.io). The app updates itself
after that.

On first launch grant **Screen Recording** and **Accessibility** when asked —
the app streams nothing and moves nothing until you do.

## Build from source

Needs Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open Pult.xcodeproj          # or: xcodebuild -scheme PultHost build
```

`Sources/PultShared` is the wire protocol (see [PROTOCOL.md](PROTOCOL.md));
`Sources/PultHost` is the capture, input, networking and menu-bar app.

## Releases

`scripts/release.sh` archives, signs with Developer ID, notarizes, staples and
zips the app, and writes `appcast.json`. CI does the same on a tag — see
[`.github/workflows/release.yml`](.github/workflows/release.yml).

## License

Source-available under [PolyForm Noncommercial 1.0.0](LICENSE): read it, build
it, run it for yourself free of charge. Commercial use needs a separate
license — open an issue.
