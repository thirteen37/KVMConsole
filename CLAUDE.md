# CLAUDE.md

Native Swift/SwiftUI macOS client for the **NanoKVM** hardware KVM-over-IP device. Bundle ID `io.lyx.NanoKVM`.

## Build / test

`project.yml` is the source of truth. After any source-tree or settings change, regenerate the Xcode project — never hand-edit `NanoKVM.xcodeproj`.

```sh
# Regenerate the Xcode project
xcodegen generate

# Run unit tests (no code signing)
xcodebuild test \
  -project NanoKVM.xcodeproj \
  -scheme NanoKVM \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=

# Local signed build (skip notarization)
NOTARIZE=0 Scripts/build-developer-id.sh
```

Release pipeline (Developer ID signing + notarization) is documented in `DeveloperRelease.md`. CI workflows live in `.github/workflows/` — `test.yml`, `build-developer-id.yml`, `release.yml`.

## Toolchain

- Swift 5.10, `SWIFT_STRICT_CONCURRENCY: complete`
- macOS 14 (Sonoma) deployment target
- Hardened runtime, app sandbox, `network.client` entitlement
- No external Swift packages — only Apple frameworks (SwiftUI, AppKit, AVFoundation, VideoToolbox, CoreMedia, CoreVideo, Security)

## Layout

`NanoKVM/`
- `App/` — `NanoKVMApp.swift` (SwiftUI entry; two windows: Connections + Viewer)
- `Models/` — `Device`, `SavedDevicesStore`
- `UI/` — `ConnectionManagerView`, `DeviceEditorView`, `ViewerView`, `ViewerViewModel`, `WindowAccessor`
- `Networking/` — `NanoKVMClient` (REST, JWT), `ControlSocket` (JSON-RPC WebSocket), `H264StreamSocket` (binary WS), `NanoKVMPasswordEncryptor`
- `Session/` — `NanoKVMSession` orchestrates client + sockets + decoder
- `Video/` — `H264Decoder` (VideoToolbox), `H264AnnexBParser`, `VideoRenderView` (Metal)
- `Input/` — `KeyboardCaptureView`, `HIDKeyboardReport`, `HIDMouseReport`, `HIDKeymap`, `FullscreenKeyCapture`
- `Persistence/` — `KeychainPasswordStore`
- `Resources/` — `Info.plist`, `NanoKVM.entitlements`
- `Assets.xcassets` — `AppIcon`

`NanoKVMTests/` — XCTest, with `MockURLSession` for network tests.

## Conventions

- Networking, session, and socket types are `actor`s. View models are `@MainActor`.
- API responses follow NanoKVM's `{code, msg, data}` envelope — see `NanoKVMClient`.
- Passwords are stored per-device in the Keychain via `KeychainPasswordStore`, never in the saved-devices JSON.
- Fullscreen exit is triple-Escape (`FullscreenKeyCapture`).
