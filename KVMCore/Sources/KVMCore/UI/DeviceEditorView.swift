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
    @State private var kind: Device.Kind
    @State private var allowsInsecureTLS: Bool
    @State private var password: String
    @State private var showPassword: Bool = false

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
            _kind = State(initialValue: .nanoKVM)
            _allowsInsecureTLS = State(initialValue: false)
            _password = State(initialValue: "")
        case .edit(let device):
            _name = State(initialValue: device.name)
            _host = State(initialValue: device.host)
            _port = State(initialValue: String(device.port))
            _scheme = State(initialValue: device.scheme)
            _username = State(initialValue: device.username)
            _kind = State(initialValue: device.kind)
            _allowsInsecureTLS = State(initialValue: device.allowsInsecureTLS)
            _password = State(initialValue: savedPassword ?? "")
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Name")
                    TextField("My KVM", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Type")
                    Picker("Type", selection: $kind) {
                        ForEach(Device.Kind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: kind) { _, newKind in
                        applyDefaults(for: newKind)
                    }
                }
                GridRow {
                    Text("Host")
                    TextField(kind == .glkvm ? "kvm.local" : "nanokvm.local", text: $host)
                        .textFieldStyle(.roundedBorder)
                }
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
                GridRow {
                    Text("Port")
                    TextField("80", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                GridRow {
                    Text("Username")
                    TextField("admin", text: $username)
                        .textFieldStyle(.roundedBorder)
                }
                if kind == .glkvm {
                    GridRow {
                        Text("TLS")
                        Toggle("Allow self-signed TLS", isOn: $allowsInsecureTLS)
                    }
                }
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
    }

    private var title: String {
        switch mode {
        case .add: return "Add Device"
        case .edit: return "Edit Device"
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isValid: Bool {
        !trimmedHost.isEmpty && !trimmedUsername.isEmpty && Int(port) != nil
    }

    private func buildDevice() -> Device {
        let resolvedPort = Int(port) ?? (scheme == .https ? 443 : 80)
        let displayName = trimmedName.isEmpty ? trimmedHost : trimmedName
        switch mode {
        case .add:
            return Device(
                name: displayName,
                host: trimmedHost,
                port: resolvedPort,
                scheme: scheme,
                username: trimmedUsername,
                kind: kind,
                allowsInsecureTLS: allowsInsecureTLS
            )
        case .edit(let existing):
            return Device(
                id: existing.id,
                name: displayName,
                host: trimmedHost,
                port: resolvedPort,
                scheme: scheme,
                username: trimmedUsername,
                kind: kind,
                allowsInsecureTLS: allowsInsecureTLS
            )
        }
    }

    private func applyDefaults(for kind: Device.Kind) {
        switch kind {
        case .nanoKVM:
            if host == "kvm.local" || host.isEmpty {
                host = "nanokvm.local"
            }
            if scheme == .https, port == "443" {
                scheme = .http
                port = "80"
            }
            allowsInsecureTLS = false
        case .glkvm:
            if host == "nanokvm.local" || host.isEmpty {
                host = "kvm.local"
            }
            if scheme == .http, port == "80" {
                scheme = .https
                port = "443"
            }
            allowsInsecureTLS = true
        }
    }
}
