import SwiftUI

public struct ConnectionManagerView: View {
    @EnvironmentObject private var devicesStore: SavedDevicesStore
    @Environment(\.openWindow) private var openWindow

    @State private var selectedDeviceID: Device.ID?
    @State private var editorMode: DeviceEditorView.Mode?
    @State private var editorSavedPassword: String?
    @State private var pendingDelete: Device?

    private let passwordStore: PasswordStore = KeychainPasswordStore()
    private let onConnect: ((Device) -> Void)?

    public init(onConnect: ((Device) -> Void)? = nil) {
        self.onConnect = onConnect
    }

    public var body: some View {
        list
            .frame(minWidth: 520, minHeight: 360)
            .toolbar { toolbarContent }
            .sheet(item: $editorMode) { mode in
                DeviceEditorView(
                    mode: mode,
                    savedPassword: editorSavedPassword,
                    onCommit: { device, password in
                        save(device: device, password: password, mode: mode)
                        editorMode = nil
                        editorSavedPassword = nil
                    },
                    onCancel: {
                        editorMode = nil
                        editorSavedPassword = nil
                    }
                )
            }
            .confirmationDialog(
                pendingDelete.map { "Delete \"\($0.name)\"?" } ?? "",
                isPresented: deleteBinding,
                presenting: pendingDelete
            ) { device in
                Button("Delete", role: .destructive) {
                    devicesStore.delete(device)
                    if selectedDeviceID == device.id {
                        selectedDeviceID = nil
                    }
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            }
    }

    private var list: some View {
        Group {
            if devicesStore.devices.isEmpty {
                emptyState
            } else {
                List(selection: $selectedDeviceID) {
                    ForEach(devicesStore.devices) { device in
                        DeviceRow(device: device)
                            .tag(device.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { connect(device) }
                            .contextMenu {
                                Button("Connect") { connect(device) }
                                Button("Edit…") { startEdit(device) }
                                Divider()
                                Button("Delete", role: .destructive) { pendingDelete = device }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No saved devices").font(.headline)
            Text("Click + to add a KVM device.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                startAdd()
            } label: {
                Label("Add", systemImage: "plus")
            }
            Button {
                if let device = selectedDevice { startEdit(device) }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .disabled(selectedDevice == nil)
            Button(role: .destructive) {
                if let device = selectedDevice { pendingDelete = device }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selectedDevice == nil)
            Button {
                if let device = selectedDevice { connect(device) }
            } label: {
                Label("Connect", systemImage: "play.fill")
            }
            .disabled(selectedDevice == nil)
        }
    }

    private var selectedDevice: Device? {
        guard let selectedDeviceID else { return nil }
        return devicesStore.device(id: selectedDeviceID)
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { newValue in if !newValue { pendingDelete = nil } }
        )
    }

    private func startAdd() {
        editorSavedPassword = nil
        editorMode = .add
    }

    private func startEdit(_ device: Device) {
        editorSavedPassword = (try? passwordStore.password(for: devicesStore.keychainAccount(for: device))) ?? nil
        editorMode = .edit(device)
    }

    private func save(device: Device, password: String, mode: DeviceEditorView.Mode) {
        switch mode {
        case .add:
            devicesStore.add(device)
        case .edit:
            devicesStore.update(device)
        }
        if !password.isEmpty {
            try? passwordStore.savePassword(password, for: devicesStore.keychainAccount(for: device))
        }
        selectedDeviceID = device.id
    }

    private func connect(_ device: Device) {
        if let onConnect {
            onConnect(device)
        } else {
            openWindow(value: device.id)
        }
    }
}

private struct DeviceRow: View {
    let device: Device

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(device.name).font(.body)
                Text(device.kind == .glkvm ? "GLKVM" : "NanoKVM")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
            }
            Text("\(device.scheme.rawValue)://\(device.host):\(device.port) — \(device.username)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

extension DeviceEditorView.Mode: Identifiable {
    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let device): return "edit-\(device.id.uuidString)"
        }
    }
}
