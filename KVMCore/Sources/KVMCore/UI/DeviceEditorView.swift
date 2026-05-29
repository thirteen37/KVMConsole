#if os(macOS)
@preconcurrency import AVFoundation
#endif
import SwiftUI

public struct DeviceEditorView: View {
    enum Mode: Equatable {
        case add
        case edit(Device)
    }

    let mode: Mode
    let onCommit: (Device, String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var scheme: Device.Scheme
    @State private var username: String
    @State private var allowsInsecureTLS: Bool
    @State private var password: String
    @State private var kvmType: Device.KVMType
    @State private var showPassword: Bool = false
    @State private var videoDeviceUniqueID: String?
    @State private var serialDevicePath: String?
    #if os(macOS)
    @State private var availableVideoDevices: [AVCaptureDevice] = []
    @State private var availableSerialPorts: [USBSerialPort] = []
    #endif

    init(
        mode: Mode,
        savedPassword: String? = nil,
        onCommit: @escaping (Device, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mode = mode
        self.onCommit = onCommit
        self.onCancel = onCancel

        switch mode {
        case .add:
            _name = State(initialValue: "")
            _host = State(initialValue: "nanokvm.local")
            _port = State(initialValue: "80")
            _scheme = State(initialValue: .http)
            _username = State(initialValue: "admin")
            _allowsInsecureTLS = State(initialValue: false)
            _password = State(initialValue: "")
            _kvmType = State(initialValue: .nanoKVMLite)
            _videoDeviceUniqueID = State(initialValue: nil)
            _serialDevicePath = State(initialValue: nil)
        case .edit(let device):
            _name = State(initialValue: device.name)
            _host = State(initialValue: device.host)
            _port = State(initialValue: String(device.port))
            _scheme = State(initialValue: device.scheme)
            _username = State(initialValue: device.username)
            _allowsInsecureTLS = State(initialValue: device.allowsInsecureTLS)
            _password = State(initialValue: savedPassword ?? "")
            _kvmType = State(initialValue: device.kvmType)
            _videoDeviceUniqueID = State(initialValue: device.videoDeviceUniqueID)
            _serialDevicePath = State(initialValue: device.serialDevicePath)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Type")
                    Picker("Type", selection: $kvmType) {
                        ForEach(Device.KVMType.userVisibleCases, id: \.self) { type in
                            HStack(spacing: 6) {
                                KVMTypeIcon(type)
                                Text(type.displayName)
                            }
                            .tag(type)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: kvmType) { _, newType in
                        applyDefaults(for: newType)
                    }
                }
                GridRow {
                    Text("Name")
                    TextField("My KVM", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                #if os(macOS)
                if isUSBType {
                    usbPickers
                }
                #endif

                if showsHost {
                    GridRow {
                        Text("Host")
                        TextField(hostPlaceholder, text: $host)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                if showsScheme {
                    GridRow {
                        Text("Scheme")
                        Picker("Scheme", selection: $scheme) {
                            Text("HTTP").tag(Device.Scheme.http)
                            Text("HTTPS").tag(Device.Scheme.https)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    }
                }
                if showsPort {
                    GridRow {
                        Text("Port")
                        TextField(portPlaceholder, text: $port)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }
                if showsUsername {
                    GridRow {
                        Text(usernameLabel)
                        TextField(usernamePlaceholder, text: $username)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                if showsTLS {
                    GridRow {
                        Text("TLS")
                        Toggle("Allow self-signed TLS", isOn: $allowsInsecureTLS)
                    }
                }
                if showsPassword {
                    GridRow {
                        Text("Password")
                        HStack(spacing: 6) {
                            Group {
                                if showPassword {
                                    TextField("Password", text: $password)
                                } else {
                                    SecureField("Password", text: $password)
                                }
                            }
                            .textFieldStyle(.roundedBorder)

                            Button {
                                showPassword.toggle()
                            } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(showPassword ? "Hide password" : "Show password")
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Save") {
                    onCommit(buildDevice(), password)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 460)
        #if os(macOS)
        .onAppear { refreshUSBDevices() }
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var usbPickers: some View {
        GridRow {
            Text("Camera")
            HStack(spacing: 6) {
                Picker("Camera", selection: cameraSelectionBinding) {
                    Text("Select…").tag(String?.none)
                    ForEach(availableVideoDevices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(Optional(device.uniqueID))
                    }
                    if let id = videoDeviceUniqueID,
                       availableVideoDevices.first(where: { $0.uniqueID == id }) == nil {
                        Text("\(id) (not connected)").tag(Optional(id))
                    }
                }
                .labelsHidden()

                refreshButton
            }
        }
        GridRow {
            Text("Serial")
            HStack(spacing: 6) {
                Picker("Serial", selection: serialSelectionBinding) {
                    Text("Select…").tag(String?.none)
                    ForEach(availableSerialPorts, id: \.path) { port in
                        Text(port.displayName).tag(Optional(port.path))
                    }
                    if let path = serialDevicePath,
                       availableSerialPorts.first(where: { $0.path == path }) == nil {
                        Text("\(path) (not connected)").tag(Optional(path))
                    }
                }
                .labelsHidden()

                refreshButton
            }
        }
    }

    private var refreshButton: some View {
        Button {
            refreshUSBDevices()
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Rescan USB devices")
    }

    private var cameraSelectionBinding: Binding<String?> {
        Binding(
            get: { videoDeviceUniqueID },
            set: { videoDeviceUniqueID = $0 }
        )
    }

    private var serialSelectionBinding: Binding<String?> {
        Binding(
            get: { serialDevicePath },
            set: { serialDevicePath = $0 }
        )
    }

    private func refreshUSBDevices() {
        availableVideoDevices = USBKVMDeviceDiscovery.videoDevices()
        availableSerialPorts = USBKVMDeviceDiscovery.serialPorts()
    }
    #endif

    private var title: String {
        switch mode {
        case .add: return "Add Device"
        case .edit: return "Edit Device"
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isRFBType: Bool {
        kvmType == .appleScreenSharing || kvmType == .vnc
    }

    private var isUSBType: Bool {
        kvmType == .nanoKVMUSB
    }

    private var showsHost: Bool { !isUSBType }
    private var showsScheme: Bool { !isRFBType && !isUSBType }
    private var showsPort: Bool { kvmType != .appleScreenSharing && !isUSBType }
    private var showsUsername: Bool { kvmType != .vnc && !isUSBType }
    private var showsTLS: Bool { kvmType == .comet }
    private var showsPassword: Bool { !isUSBType }

    private var hostPlaceholder: String {
        switch kvmType {
        case .comet: return "kvm.local"
        case .appleScreenSharing, .vnc: return "<hostname-or-IP>"
        case .nanoKVMLite, .nanoKVMUSB: return "nanokvm.local"
        }
    }

    private var portPlaceholder: String {
        kvmType == .vnc ? "5900" : "80"
    }

    private var usernameLabel: String {
        kvmType == .appleScreenSharing ? "Account" : "Username"
    }

    private var usernamePlaceholder: String {
        kvmType == .appleScreenSharing ? "macOS account" : "admin"
    }

    private var isValid: Bool {
        if isUSBType {
            return (videoDeviceUniqueID?.isEmpty == false)
                && (serialDevicePath?.isEmpty == false)
        }
        let hasRequiredUsername = !showsUsername || !trimmedUsername.isEmpty
        return !trimmedHost.isEmpty && hasRequiredUsername && (kvmType == .appleScreenSharing || resolvedPortValue != nil)
    }

    private func buildDevice() -> Device {
        let resolvedPort = kvmType == .appleScreenSharing ? 5900 : resolvedPortValue ?? defaultPort
        let displayName: String
        if !trimmedName.isEmpty {
            displayName = trimmedName
        } else if isUSBType {
            displayName = kvmType.displayName
        } else {
            displayName = trimmedHost
        }
        let resolvedUsername = kvmType == .vnc ? "" : trimmedUsername
        let resolvedScheme = isRFBType ? .http : scheme
        let resolvedAllowsInsecureTLS = isRFBType ? false : allowsInsecureTLS
        let resolvedHost = isUSBType ? "" : trimmedHost
        let resolvedVideoID = isUSBType ? videoDeviceUniqueID : nil
        let resolvedSerial = isUSBType ? serialDevicePath : nil
        switch mode {
        case .add:
            return Device(
                name: displayName,
                host: resolvedHost,
                port: resolvedPort,
                scheme: resolvedScheme,
                username: resolvedUsername,
                kvmType: kvmType,
                allowsInsecureTLS: resolvedAllowsInsecureTLS,
                videoDeviceUniqueID: resolvedVideoID,
                serialDevicePath: resolvedSerial
            )
        case .edit(let existing):
            return Device(
                id: existing.id,
                name: displayName,
                host: resolvedHost,
                port: resolvedPort,
                scheme: resolvedScheme,
                username: resolvedUsername,
                kvmType: kvmType,
                allowsInsecureTLS: resolvedAllowsInsecureTLS,
                lastConnectedAt: existing.lastConnectedAt,
                videoDeviceUniqueID: resolvedVideoID,
                serialDevicePath: resolvedSerial
            )
        }
    }

    private var resolvedPortValue: Int? {
        guard let parsed = Int(port), (0...Int(UInt16.max)).contains(parsed) else { return nil }
        return parsed
    }

    private var defaultPort: Int {
        switch kvmType {
        case .appleScreenSharing, .vnc: return 5900
        default: return scheme == .https ? 443 : 80
        }
    }

    private func applyDefaults(for type: Device.KVMType) {
        switch type {
        case .nanoKVMUSB:
            // Host/username/password rows are hidden for NanoKVM USB (see showsHost/
            // showsUsername/showsPassword), so leave that state untouched — clearing it
            // would discard the user's input if they switch types back and forth.
            allowsInsecureTLS = false
        case .nanoKVMLite:
            if host.isEmpty || host == "kvm.local" {
                host = "nanokvm.local"
            }
            if scheme == .https, port == "443" {
                scheme = .http
                port = "80"
            }
            allowsInsecureTLS = false
        case .comet:
            if host == "nanokvm.local" || host.isEmpty {
                host = "kvm.local"
            }
            if scheme == .http, port == "80" {
                scheme = .https
                port = "443"
            }
            allowsInsecureTLS = true
        case .appleScreenSharing:
            if host == "nanokvm.local" || host == "kvm.local" {
                host = ""
            }
            scheme = .http
            port = "5900"
            allowsInsecureTLS = false
        case .vnc:
            if host == "nanokvm.local" || host == "kvm.local" {
                host = ""
            }
            scheme = .http
            if port == "80" || port == "443" || port.isEmpty {
                port = "5900"
            }
            allowsInsecureTLS = false
        }
    }
}
