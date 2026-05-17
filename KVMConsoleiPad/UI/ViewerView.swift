import KVMCore
import SwiftUI

struct ViewerHostView: View {
    let deviceID: Device.ID?
    @EnvironmentObject private var devicesStore: SavedDevicesStore

    var body: some View {
        Group {
            if let deviceID, let device = devicesStore.device(id: deviceID) {
                ViewerView(device: device)
                    .navigationTitle(device.name)
            } else {
                missingDevice
            }
        }
    }

    private var missingDevice: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text("Device not found")
                .font(.headline)
            Text("This device is no longer in your saved list.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ViewerView: View {
    @StateObject private var model: ViewerViewModel
    @State private var modifierState = ModifierKeyState()
    @State private var showModifierBar = true
    @State private var keyboardFocusToken = 0
    @State private var pendingVirtualKey: VirtualKeyTap?

    init(device: Device) {
        _model = StateObject(wrappedValue: ViewerViewModel(device: device))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            videoArea

            if model.passwordPrompt != nil {
                passwordPromptOverlay
            }

            if showModifierBar, model.passwordPrompt == nil {
                ModifierKeyBar(state: $modifierState) { usage, modifier in
                    sendVirtualKey(usage: usage, modifier: modifier)
                }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(Color.black)
        .toolbar { toolbarContent }
        .onDisappear {
            model.disconnect()
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

            PointerCaptureView(
                isEnabled: model.isStreaming && model.isMouseCaptureEnabled,
                isScrollInverted: model.isScrollInverted,
                videoSize: model.videoSize,
                zoom: model.zoom,
                onMouseReport: { report in model.sendMouseReport(report) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            KeyboardCaptureView(
                isEnabled: model.isStreaming && model.isKeyboardCaptureEnabled,
                keyboardFocusToken: keyboardFocusToken,
                extraModifierByte: modifierState.activeModifierByte,
                pendingVirtualKey: pendingVirtualKey,
                onKeyboardReport: { report in model.sendKeyboardReport(report) },
                onMomentaryModifiersConsumed: { modifierState.consumeMomentary() }
            )
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)

            MinimapView(zoom: model.zoom)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .allowsHitTesting(false)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Toggle(isOn: $model.isKeyboardCaptureEnabled) {
                Label("Keyboard", systemImage: "keyboard")
            }
            Toggle(isOn: $model.isMouseCaptureEnabled) {
                Label("Pointer", systemImage: "cursorarrow")
            }
            Toggle(isOn: $model.isScrollInverted) {
                Label("Invert Scroll", systemImage: "arrow.up.arrow.down")
            }
            Toggle(isOn: $showModifierBar) {
                Label("Modifiers", systemImage: "command")
            }
            Button {
                keyboardFocusToken += 1
            } label: {
                Label("Show Keyboard", systemImage: "keyboard.chevron.compact.down")
            }
            Text(model.state.displayText)
                .foregroundStyle(statusColor)
            if model.powerControl != nil {
                Menu {
                    Button("On") { model.powerOn() }
                    Button("Off") { model.powerOff() }
                    Button("Force Off") { model.forceOff() }
                    Divider()
                    Button("Reset") { model.resetPower() }
                    Button("Long Press Power") { model.longPressPower() }
                } label: {
                    Label("Power", systemImage: "power")
                }
            }
            Button(model.isStreaming ? "Disconnect" : "Reconnect") {
                if model.isStreaming {
                    model.disconnect()
                } else {
                    model.reconnect()
                }
            }
        }
    }

    private var passwordPromptOverlay: some View {
        VStack(spacing: 12) {
            Text("Enter password for \(model.device.username)@\(model.device.host)")
                .font(.headline)
            SecureField("Password", text: $model.passwordInput)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.go)
                .onSubmit { model.submitPassword() }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .lineLimit(3)
            }

            HStack {
                Button("Connect") { model.submitPassword() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.passwordInput.isEmpty)
            }
        }
        .padding(20)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusColor: Color {
        switch model.state {
        case .streaming: return .green
        case .error: return .red
        case .connecting: return .orange
        case .disconnected: return .secondary
        }
    }

    private func sendVirtualKey(usage: UInt8, modifier: UInt8) {
        pendingVirtualKey = VirtualKeyTap(id: UUID(), usage: usage, transientModifier: modifier)
    }
}
