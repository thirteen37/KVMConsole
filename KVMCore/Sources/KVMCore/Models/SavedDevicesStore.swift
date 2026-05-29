import Foundation

@MainActor
public final class SavedDevicesStore: ObservableObject {
    @Published public private(set) var devices: [Device] = []

    private let storeURL: URL
    private let passwordStore: PasswordStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        storeURL: URL? = nil,
        passwordStore: PasswordStore = KeychainPasswordStore()
    ) {
        let resolvedStoreURL = storeURL ?? Self.defaultStoreURL()
        self.storeURL = resolvedStoreURL
        self.passwordStore = passwordStore
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        if storeURL == nil {
            Self.migrateFromSandboxContainerIfNeeded(to: resolvedStoreURL)
        }
        load()
    }

    public func device(id: Device.ID) -> Device? {
        devices.first { $0.id == id }
    }

    public func add(_ device: Device) {
        devices.append(device)
        persist()
    }

    public func update(_ device: Device) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        let old = devices[index]
        devices[index] = device

        let oldAccount = keychainAccount(for: old)
        let newAccount = keychainAccount(for: device)
        if oldAccount != newAccount {
            migratePassword(from: oldAccount, to: newAccount)
        }
        persist()
    }

    public func markConnected(_ id: Device.ID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].lastConnectedAt = Date()
        persist()
    }

    public func delete(_ device: Device) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices.remove(at: index)
        try? passwordStore.deletePassword(for: keychainAccount(for: device))
        persist()
    }

    public func keychainAccount(for device: Device) -> String {
        KeychainPasswordAccount(
            scheme: device.scheme,
            host: device.host,
            port: device.port,
            username: device.username
        ).rawValue
    }

    private func migratePassword(from oldAccount: String, to newAccount: String) {
        do {
            guard let password = try passwordStore.password(for: oldAccount) else { return }
            try passwordStore.savePassword(password, for: newAccount)
            try passwordStore.deletePassword(for: oldAccount)
        } catch {
            // Best-effort migration; the user can re-enter the password if it doesn't carry over.
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        guard let decoded = try? decoder.decode([Device].self, from: data) else { return }
        devices = decoded
    }

    private func persist() {
        let directory = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(devices) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    /// The macOS app dropped the App Sandbox to gain raw serial access for NanoKVM USB.
    /// `.applicationSupportDirectory` was previously redirected into the sandbox container,
    /// so a one-time copy brings a prior sandboxed build's `devices.json` to the new
    /// unsandboxed location. Best-effort and idempotent: it only runs when no store exists
    /// yet at the destination and a legacy container file is present.
    private static func migrateFromSandboxContainerIfNeeded(to destination: URL) {
        #if os(macOS)
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else { return }

        let bundleID = Bundle.main.bundleIdentifier ?? "io.lyx.KVMConsole"
        let legacy = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Data/Library/Application Support", isDirectory: true)
            .appendingPathComponent("io.lyx.KVMConsole", isDirectory: true)
            .appendingPathComponent("devices.json", isDirectory: false)
        guard fileManager.fileExists(atPath: legacy.path) else { return }

        try? fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.copyItem(at: legacy, to: destination)
        #endif
    }

    private static func defaultStoreURL() -> URL {
        let fileManager = FileManager.default
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("io.lyx.KVMConsole", isDirectory: true)
            .appendingPathComponent("devices.json", isDirectory: false)
    }
}
