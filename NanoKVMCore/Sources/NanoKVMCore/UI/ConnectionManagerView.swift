import SwiftUI

public struct ConnectionManagerView: View {
    @EnvironmentObject private var devicesStore: SavedDevicesStore
    @Environment(\.openWindow) private var openWindow

    @AppStorage("connectionListLayout") private var layoutRawValue = ConnectionListLayout.list.rawValue
    @State private var selectedDeviceID: Device.ID?
    @State private var editorMode: DeviceEditorView.Mode?
    @State private var editorSavedPassword: String?
    @State private var pendingDelete: Device?
    @State private var searchQuery = ""

    private let passwordStore: PasswordStore = KeychainPasswordStore()
    private let onConnect: ((Device) -> Void)?

    public init(onConnect: ((Device) -> Void)? = nil) {
        self.onConnect = onConnect
    }

    public var body: some View {
        content
            .frame(minWidth: 520, minHeight: 360)
            .navigationTitle("All Connections")
            .toolbar { toolbarContent }
            .searchable(text: $searchQuery, placement: .toolbar, prompt: "Search")
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

    private var content: some View {
        Group {
            if devicesStore.devices.isEmpty {
                emptyState
            } else if filteredDevices.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if layout == .grid {
                grid
            } else {
                list
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var list: some View {
        List(selection: $selectedDeviceID) {
            ForEach(filteredDevices) { device in
                DeviceRow(
                    device: device,
                    lastConnectedText: lastConnectedString(device.lastConnectedAt),
                    onEdit: { startEdit(device) }
                )
                .tag(device.id)
                .contentShape(Rectangle())
                .onTapGesture { handleSingleTap(device) }
                .onTapGesture(count: 2) { connect(device) }
                .contextMenu { contextMenu(for: device) }
            }
        }
        .connectionListStyle()
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140), spacing: 16)],
                spacing: 16
            ) {
                ForEach(filteredDevices) { device in
                    DeviceGridCell(device: device, isSelected: selectedDeviceID == device.id)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { handleSingleTap(device) }
                        .onTapGesture(count: 2) { connect(device) }
                        .contextMenu { contextMenu(for: device) }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No saved devices").font(.headline)
            Text("Click + to add a NanoKVM.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Layout", selection: layoutBinding) {
                Label("Grid", systemImage: "square.grid.2x2")
                    .labelStyle(.iconOnly)
                    .tag(ConnectionListLayout.grid)
                Label("List", systemImage: "list.bullet")
                    .labelStyle(.iconOnly)
                    .tag(ConnectionListLayout.list)
            }
            .pickerStyle(.segmented)
            .help("Layout")

            Button {
                startAdd()
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add connection")
        }
    }

    private var layout: ConnectionListLayout {
        get { ConnectionListLayout(rawValue: layoutRawValue) ?? .list }
        nonmutating set { layoutRawValue = newValue.rawValue }
    }

    private var layoutBinding: Binding<ConnectionListLayout> {
        Binding(
            get: { layout },
            set: { layout = $0 }
        )
    }

    private var filteredDevices: [Device] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return devicesStore.devices }
        return devicesStore.devices.filter { device in
            device.name.localizedCaseInsensitiveContains(query)
                || device.host.localizedCaseInsensitiveContains(query)
        }
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

    private func handleSingleTap(_ device: Device) {
        selectedDeviceID = device.id
#if os(iOS)
        connect(device)
#endif
    }

    @ViewBuilder
    private func contextMenu(for device: Device) -> some View {
        Button("Connect") { connect(device) }
        Button("Edit…") { startEdit(device) }
        Divider()
        Button("Delete", role: .destructive) { pendingDelete = device }
    }

    private static let timeStyle = Date.FormatStyle.dateTime.hour().minute()
    private static let dayMonthStyle = Date.FormatStyle.dateTime.day().month(.abbreviated)
    private static let dayMonthYearStyle = Date.FormatStyle.dateTime.day().month(.abbreviated).year()

    private func lastConnectedString(_ date: Date?) -> String {
        guard let date else { return "" }

        let calendar = Calendar.current
        let time = date.formatted(Self.timeStyle)

        if calendar.isDateInToday(date) {
            return "Today at \(time)"
        }

        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        let dayMonth = date.formatted(sameYear ? Self.dayMonthStyle : Self.dayMonthYearStyle)
        return "\(dayMonth) at \(time)"
    }
}

private enum ConnectionListLayout: String, Hashable {
    case grid
    case list
}

private struct DeviceRow: View {
    let device: Device
    let lastConnectedText: String
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            KVMTypeIcon(device.kvmType, size: 20)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.body.weight(.semibold))
                Text(device.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Text(lastConnectedText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button(action: onEdit) {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Edit \(device.name)")
            .help("Edit")
        }
        .padding(.vertical, 4)
    }
}

private struct DeviceGridCell: View {
    let device: Device
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            KVMTypeIcon(device.kvmType, size: 36)
                .frame(height: 42)

            VStack(spacing: 2) {
                Text(device.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(device.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(.center)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 112)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: 2)
                .opacity(isSelected ? 1 : 0)
        }
    }
}

private extension View {
    @ViewBuilder
    func connectionListStyle() -> some View {
#if os(macOS)
        self.listStyle(.inset)
            .alternatingRowBackgrounds()
#else
        self.listStyle(.inset)
#endif
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
