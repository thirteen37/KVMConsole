import AppKit
import NanoKVMCore
import SwiftUI

struct ViewerHostView: View {
    let deviceID: Device.ID?
    @EnvironmentObject private var devicesStore: SavedDevicesStore

    var body: some View {
        Group {
            if let deviceID, let device = devicesStore.device(id: deviceID) {
                ViewerView(device: device) { id in
                    devicesStore.markConnected(id)
                }
                    .navigationTitle(device.name)
                    .navigationSubtitle(device.host)
            } else {
                missingDevice
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    private var missingDevice: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text("Device not found")
                .font(.headline)
            Text("This NanoKVM device is no longer in your saved list.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ViewerView: View {
    @StateObject private var model: ViewerViewModel
    @State private var window: NSWindow?
    @State private var coordinator: FullscreenKeyCaptureCoordinator?
    @State private var toolbarHideTask: Task<Void, Never>?

    private static let toolbarHideDelayNs: UInt64 = 2_000_000_000

    init(device: Device, onConnected: ((Device.ID) -> Void)? = nil) {
        _model = StateObject(wrappedValue: ViewerViewModel(device: device, onConnected: onConnected))
    }

    var body: some View {
        ZStack(alignment: .top) {
            videoArea

            if model.showFullscreenBanner {
                fullscreenBanner
                    .transition(.opacity)
                    .frame(maxHeight: .infinity, alignment: .top)
            }

            if model.passwordPrompt != nil {
                passwordPromptOverlay
            }
        }
        .background(WindowAccessor { newWindow in
            attachWindow(newWindow)
        })
        .toolbar { toolbarContent }
        .animation(.easeInOut(duration: 0.25), value: model.showFullscreenBanner)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            guard let w = note.object as? NSWindow, w === window else { return }
            handleEnterFullScreen()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard let w = note.object as? NSWindow, w === window else { return }
            handleExitFullScreen()
        }
        .onDisappear {
            cleanup()
        }
    }

    private var videoArea: some View {
        ZStack {
            Color.black

            VideoRenderView(
                renderCoordinator: model.renderCoordinator,
                scale: model.zoom.scale,
                center: model.zoom.center,
                videoSize: model.videoSize
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            KeyboardCaptureView(
                isKeyboardEnabled: model.isStreaming && model.isKeyboardCaptureEnabled && !model.isFullscreen,
                isMouseEnabled: model.isStreaming && model.isMouseCaptureEnabled,
                isScrollInverted: model.isScrollInverted,
                videoSize: model.videoSize,
                zoom: model.zoom,
                onKeyboardReport: { report in model.sendKeyboardReport(report) },
                onMouseReport: { report in model.sendMouseReport(report) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            MinimapView(zoom: model.zoom)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .allowsHitTesting(false)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $model.isKeyboardCaptureEnabled) {
                Label("Keyboard", systemImage: "keyboard")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help("Keyboard capture")

            Toggle(isOn: $model.isMouseCaptureEnabled) {
                Label("Mouse", systemImage: "cursorarrow")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help("Mouse capture")

            Toggle(isOn: $model.isScrollInverted) {
                Label("Invert Scroll", systemImage: "arrow.up.arrow.down")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help("Invert scroll")

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 92, alignment: .leading)
            }

            Button {
                if model.isStreaming {
                    model.disconnect()
                } else {
                    model.reconnect()
                }
            } label: {
                Label(
                    model.isStreaming ? "Disconnect" : "Reconnect",
                    systemImage: model.isStreaming ? "xmark.circle" : "arrow.clockwise"
                )
                .frame(minWidth: 92, alignment: .leading)
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.small)
        }
    }

    private var fullscreenBanner: some View {
        Text("Capturing keys — triple-Esc to release")
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 60)
    }

    private var passwordPromptOverlay: some View {
        VStack(spacing: 12) {
            Text("Enter password for \(model.device.username)@\(model.device.host)")
                .font(.headline)
            SecureField("Password", text: $model.passwordInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { model.submitPassword() }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .lineLimit(3)
            }

            HStack {
                Button("Connect") { model.submitPassword() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.passwordInput.isEmpty)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 360)
    }

    private var statusColor: Color {
        switch model.status {
        case "Streaming": return .green
        case "Error": return .red
        case "Connecting...": return .orange
        default: return .secondary
        }
    }

    private func attachWindow(_ newWindow: NSWindow?) {
        window = newWindow
        guard let newWindow else {
            model.toggleFullscreen = nil
            return
        }
        newWindow.collectionBehavior.insert(.fullScreenPrimary)
        model.toggleFullscreen = { [weak newWindow] in
            newWindow?.toggleFullScreen(nil)
        }
    }

    private func handleEnterFullScreen() {
        guard let window else { return }
        window.toolbar?.isVisible = false
        model.isFullscreen = true
        let coord = FullscreenKeyCaptureCoordinator(
            isCapturing: { [model] in model.isKeyboardCaptureEnabled },
            onKeyboardReport: { [model] report in model.sendKeyboardReport(report) },
            onTripleEscape: { [model] in model.handleTripleEscape() },
            onTopEdgeHover: { revealToolbar() },
            onTopEdgeLeft: { scheduleToolbarHide() }
        )
        coord.start(window: window)
        coordinator = coord
        model.presentFullscreenBanner()
    }

    private func handleExitFullScreen() {
        coordinator?.stop()
        coordinator = nil
        toolbarHideTask?.cancel()
        toolbarHideTask = nil
        window?.toolbar?.isVisible = true
        model.isFullscreen = false
        model.clearFullscreenBanner()
    }

    private func revealToolbar() {
        toolbarHideTask?.cancel()
        toolbarHideTask = nil
        window?.toolbar?.isVisible = true
    }

    private func scheduleToolbarHide() {
        guard window?.toolbar?.isVisible == true else { return }
        toolbarHideTask?.cancel()
        toolbarHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.toolbarHideDelayNs)
            guard !Task.isCancelled else { return }
            window?.toolbar?.isVisible = false
        }
    }

    private func cleanup() {
        coordinator?.stop()
        coordinator = nil
        toolbarHideTask?.cancel()
        toolbarHideTask = nil
        model.clearFullscreenBanner()
        model.disconnect()
    }
}
