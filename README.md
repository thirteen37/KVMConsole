# NanoKVM for macOS and iPadOS

A native SwiftUI client for [NanoKVM](https://github.com/sipeed/NanoKVM) hardware KVM-over-IP devices. Manage saved connections, view the remote system's H.264 video stream, and send keyboard and mouse input from a Mac or iPad app, without a browser.

I started this after using NanoKVM to drive my spare Mac in the closet for AI-agent workflows. The goal is a KVM client that feels closer to sitting at the machine: shortcuts arrive at the remote host, pointer and scroll input behave predictably, and the video path stays low-latency.

## Features

- Manage multiple NanoKVM devices, each with its own URL, port, and credentials
- Per-device passwords stored securely in the Apple Keychain
- Hardware-accelerated H.264 decoding via VideoToolbox; rendered with Metal
- Lower-latency native video and input path than driving the NanoKVM through a browser
- Full keyboard capture, including shortcuts such as Cmd-W that browsers normally intercept
- More reliable scrolling and absolute-positioning mouse input over the device's HID WebSocket
- iPadOS support with better hardware keyboard, modifier-key, pointer, and scrolling behavior
- Pinch-to-zoom on the remote video with a bottom-right minimap; pinching also pans (the grabbed video point follows the fingers), and the viewport follows the remote cursor toward the edges when zoomed in
- macOS fullscreen viewer with triple-Escape to exit
- Connection heartbeat with automatic state surfacing in the UI

## Requirements

- macOS 15 (Sequoia) or later for the Mac app
- iPadOS 26 or later for the iPad app
- A NanoKVM device reachable over the network

## Install

For macOS, download the notarized `NanoKVM-<tag>-DeveloperID-notarized.zip` from the latest [GitHub Release](../../releases), unzip, and drag `NanoKVM.app` into `/Applications`.

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

To run the iPadOS unit tests in Simulator:

```sh
xcodebuild test \
  -project NanoKVM.xcodeproj \
  -scheme NanoKVMiPad \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)'
```

To produce a locally signed build (no notarization):

```sh
NOTARIZE=0 Scripts/build-developer-id.sh
```

The app uses only Apple frameworks (SwiftUI, AppKit/UIKit, AVFoundation, VideoToolbox, CoreMedia, CoreVideo, Security) — no third-party Swift packages.

## Project layout

```
NanoKVMCore/     Shared Swift package for networking, sessions, video, input, UI, and persistence
NanoKVM/
  App/           macOS SwiftUI entry point
  UI/            macOS viewer windows
  Input/         macOS keyboard capture
  Video/         macOS Metal render view
  Resources/     macOS Info.plist, entitlements
NanoKVMiPad/
  App/           iPadOS SwiftUI entry point
  UI/            iPad viewer and modifier-key controls
  Input/         iPad keyboard and pointer capture
  Video/         iPad Metal render view
  Resources/     iPadOS Info.plist, entitlements
NanoKVMTests/    macOS XCTest unit tests
NanoKVMiPadTests/  iPadOS XCTest unit tests
Scripts/         Signed/notarized macOS build pipeline
```

## Releasing

See [`DeveloperRelease.md`](DeveloperRelease.md) for the Developer ID signing and notarization workflow used by the GitHub Actions release pipeline.

## License

NanoKVM for macOS and iPadOS is released under the [MIT License](LICENSE).
