# NanoKVM for macOS

A native SwiftUI client for [NanoKVM](https://github.com/sipeed/NanoKVM) hardware KVM-over-IP devices. Manage saved connections, view the remote system's H.264 video stream, and send keyboard and mouse input — all from a Mac app, without a browser.

## Features

- Manage multiple NanoKVM devices, each with its own URL, port, and credentials
- Per-device passwords stored securely in the macOS Keychain
- Hardware-accelerated H.264 decoding via VideoToolbox; rendered with Metal
- Full keyboard and absolute-positioning mouse input over the device's HID WebSocket
- Fullscreen viewer with triple-Escape to exit
- Connection heartbeat with automatic state surfacing in the UI

## Requirements

- macOS 14 (Sonoma) or later
- A NanoKVM device reachable over the network

## Install

Download the notarized `NanoKVM-<tag>-DeveloperID-notarized.zip` from the latest [GitHub Release](../../releases), unzip, and drag `NanoKVM.app` into `/Applications`.

## Build from source

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate
open NanoKVM.xcodeproj
```

To run the unit tests from the command line without signing:

```sh
xcodebuild test \
  -project NanoKVM.xcodeproj \
  -scheme NanoKVM \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=
```

To produce a locally signed build (no notarization):

```sh
NOTARIZE=0 Scripts/build-developer-id.sh
```

The app uses only Apple frameworks (SwiftUI, AppKit, AVFoundation, VideoToolbox, CoreMedia, CoreVideo, Security) — no third-party Swift packages.

## Project layout

```
NanoKVM/
  App/           SwiftUI entry point
  Models/        Device + saved-devices store
  UI/            Connection manager and viewer windows
  Networking/    REST client, control + H.264 WebSockets
  Session/       Orchestrates client, sockets, and decoder
  Video/         H.264 Annex B parser, VideoToolbox decoder, Metal render view
  Input/         HID keyboard/mouse reports and key capture
  Persistence/   Keychain-backed password store
  Resources/     Info.plist, entitlements
NanoKVMTests/    XCTest unit tests
Scripts/         Signed/notarized build pipeline
```

## Releasing

See [`DeveloperRelease.md`](DeveloperRelease.md) for the Developer ID signing and notarization workflow used by the GitHub Actions release pipeline.

## License

NanoKVM for macOS is released under the [MIT License](LICENSE).
