# CLAUDE.md

Native Swift/SwiftUI client for the **NanoKVM** hardware KVM-over-IP device. Two app targets — macOS (`NanoKVM`) and iPadOS (`NanoKVMiPad`) — share a local Swift package `NanoKVMCore` for networking, session, video decode, HID reports, persistence, and the cross-platform SwiftUI views. Both apps ship under bundle ID `io.lyx.NanoKVM`.

## Build / test

`project.yml` is the source of truth. After any source-tree or settings change, regenerate the Xcode project — never hand-edit `NanoKVM.xcodeproj`.

```sh
# Regenerate the Xcode project
xcodegen generate

# macOS unit tests (no code signing)
xcodebuild test \
  -project NanoKVM.xcodeproj \
  -scheme NanoKVM \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=

# iPadOS unit tests (simulator)
xcodebuild test \
  -project NanoKVM.xcodeproj \
  -scheme NanoKVMiPad \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=

# Package-only tests (no Xcode project needed)
swift test --package-path NanoKVMCore

# Local signed macOS build (skip notarization)
NOTARIZE=0 Scripts/build-developer-id.sh
```

Release pipeline (Developer ID signing + notarization, macOS only) is documented in `DeveloperRelease.md`. CI workflows live in `.github/workflows/` — `test.yml` (macOS + iPadOS), `build-developer-id.yml`, `release.yml`. iPad TestFlight/App Store distribution is not yet wired up.

## Toolchain

- Swift 6.0, `SWIFT_STRICT_CONCURRENCY: complete`
- macOS 26 / iPadOS 26 deployment target
- iPadOS app: `TARGETED_DEVICE_FAMILY=2` (iPad only — no iPhone, no Catalyst)
- macOS app: hardened runtime, app sandbox, `network.client` entitlement
- No external Swift packages — only Apple frameworks (SwiftUI, AppKit/UIKit, AVFoundation, VideoToolbox, CoreMedia, CoreVideo, Security)

## Layout

`NanoKVMCore/` — local Swift package, depended on by both app targets.
`Sources/NanoKVMCore/`
- `Models/` — `Device`, `SavedDevicesStore`
- `Networking/` — `NanoKVMClient` (REST, JWT), `ControlSocket` (JSON-RPC WebSocket), `H264StreamSocket` (binary WS), `NanoKVMPasswordEncryptor`
- `Session/` — `NanoKVMSession` orchestrates client + sockets + decoder
- `Video/` — `H264Decoder` (VideoToolbox), `H264AnnexBParser`, `SampleBufferDisplay` (shared `AVSampleBufferDisplayLayer` config)
- `Input/` — `HIDKeyboardReport`, `HIDMouseReport`, `HIDModifierBit`, `MouseScrollAccumulator`, `MouseCoordinateMapper`, `TripleEscapeDetector`
- `Persistence/` — `KeychainPasswordStore`
- `UI/` — `ConnectionManagerView`, `DeviceEditorView`, `ViewerViewModel` (pure SwiftUI, used by both apps)

`NanoKVM/` — macOS app target.
- `App/NanoKVMApp.swift` — two-window SwiftUI entry (Connections + Viewer `WindowGroup`)
- `UI/` — `ViewerView`, `ViewerHostView`, `WindowAccessor`
- `Input/` — `KeyboardCaptureView` (NSView responder chain), `FullscreenKeyCapture` (NSEvent local monitor), `HIDKeymap` (Mac virtual keycode → HID usage)
- `Video/VideoRenderView.swift` — `NSViewRepresentable` wrapper over `SampleBufferDisplay`
- `Resources/` — `Info.plist`, `NanoKVM.entitlements`
- `Assets.xcassets/AppIcon`

`NanoKVMiPad/` — iPadOS app target.
- `App/NanoKVMiPadApp.swift` — single `WindowGroup` with a `NavigationStack`; the Connection list pushes the Viewer (one connection at a time, no multi-scene)
- `UI/` — `ViewerView`, `ViewerHostView`, `ModifierKeyBar` (Ctrl/Alt/Cmd/Shift/Win on-screen bar, tap = momentary, long-press = lock)
- `Input/` — `KeyboardCaptureView` (`UIPress`/`UIKey`), `PointerCaptureView` (`UIHover`/`UIPan`/`UITap`)
- `Video/VideoRenderView.swift` — `UIViewRepresentable` wrapper over `SampleBufferDisplay`
- `Resources/` — `Info.plist`, `NanoKVM.entitlements`
- `Assets.xcassets/AppIcon`

`NanoKVMTests/` — XCTest for Mac-only code (`HIDKeymap`, `KeychainPasswordStore`).
`NanoKVMiPadTests/` — XCTest for iPad-only code (UIKey-to-HID, modifier-bar state).
`NanoKVMCore/Tests/NanoKVMCoreTests/` — cross-platform tests (parsers, networking, HID reports, etc.).

## Conventions

- Networking, session, and socket types are `actor`s. View models are `@MainActor`.
- API responses follow NanoKVM's `{code, msg, data}` envelope — see `NanoKVMClient`.
- Passwords are stored per-device in the Keychain via `KeychainPasswordStore`, never in the saved-devices JSON.
- macOS fullscreen exit is triple-Escape (`FullscreenKeyCapture`). iPad has no fullscreen capture mode.
- iPad supports a single active KVM connection at a time (single-scene NavigationStack); macOS allows multiple viewer windows side-by-side.
