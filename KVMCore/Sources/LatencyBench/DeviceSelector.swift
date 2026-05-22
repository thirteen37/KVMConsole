#if os(macOS)
import Foundation
import KVMCore

/// Discovers and selects a `Device` for a bench run.
///
/// Resolution rules:
/// - If `--device <name-or-uuid>` matches a saved device, use it (Keychain
///   password lookup, falling back to a TTY prompt).
/// - Otherwise, drop into an interactive TTY prompt that mirrors the
///   `ConnectionManagerView` form.
enum DeviceSelector {
    struct Selection {
        let device: Device
        let password: String
        let passwordAccount: String
    }

    /// Candidate `devices.json` paths in priority order. KVM Console is
    /// sandboxed, so its `devices.json` lives inside the app container —
    /// reading it requires Full Disk Access on the terminal running the
    /// bench. The user-level Application Support path is checked as a
    /// fallback for unsandboxed dev builds.
    static func candidateStoreURLs(override: URL? = nil) -> [URL] {
        var urls: [URL] = []
        if let override { urls.append(override) }

        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        urls.append(
            home.appendingPathComponent(
                "Library/Containers/io.lyx.KVMConsole/Data/Library/Application Support/io.lyx.KVMConsole/devices.json"
            )
        )
        if let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            urls.append(
                appSupport
                    .appendingPathComponent("io.lyx.KVMConsole", isDirectory: true)
                    .appendingPathComponent("devices.json", isDirectory: false)
            )
        }
        return urls
    }

    /// Picks the first candidate `devices.json` that exists and is readable.
    /// Returns nil if none are.
    static func resolveStoreURL(override: URL? = nil) -> URL? {
        candidateStoreURLs(override: override).first(where: { url in
            FileManager.default.isReadableFile(atPath: url.path)
        })
    }

    @MainActor
    static func listSavedDevices(storeURL: URL? = nil) -> [Device] {
        let url = resolveStoreURL(override: storeURL)
        return SavedDevicesStore(storeURL: url).devices
    }

    @MainActor
    static func resolve(
        identifier: String?,
        requireKVMType: Set<Device.KVMType>?,
        storeURL: URL? = nil
    ) throws -> Selection {
        let resolved = resolveStoreURL(override: storeURL)
        let store = SavedDevicesStore(storeURL: resolved)
        let passwordStore = KeychainPasswordStore()

        let device: Device
        if let identifier, let match = matchSaved(identifier: identifier, in: store.devices) {
            device = match
        } else if identifier == nil, store.devices.count == 1 {
            device = store.devices[0]
        } else if identifier == nil {
            device = try TTYPrompt.promptForDevice(existing: store.devices)
        } else {
            throw DeviceSelectorError.deviceNotFound(identifier ?? "")
        }

        if let requireKVMType, !requireKVMType.contains(device.kvmType) {
            throw DeviceSelectorError.wrongKVMType(
                got: device.kvmType,
                expected: requireKVMType.map { $0.displayName }.sorted().joined(separator: ", ")
            )
        }

        let account = store.keychainAccount(for: device)
        let password: String
        if let stored = (try? passwordStore.password(for: account)), !stored.isEmpty {
            password = stored
        } else {
            password = TTYPrompt.promptForPassword(
                prompt: "Password for \(device.username)@\(device.host): "
            )
        }

        let normalizedDevice = normalizedForBench(device)
        if normalizedDevice.port != device.port {
            FileHandle.standardError.write(Data(
                "Using \(normalizedDevice.kvmType.displayName) default port \(normalizedDevice.port) instead of saved port \(device.port).\n".utf8
            ))
        }

        return Selection(device: normalizedDevice, password: password, passwordAccount: account)
    }

    private static func matchSaved(identifier: String, in devices: [Device]) -> Device? {
        if let uuid = UUID(uuidString: identifier), let match = devices.first(where: { $0.id == uuid }) {
            return match
        }
        let lowered = identifier.lowercased()
        if let match = devices.first(where: { $0.name.lowercased() == lowered }) {
            return match
        }
        if let match = devices.first(where: { $0.name.lowercased().hasPrefix(lowered) }) {
            return match
        }
        return devices.first(where: { $0.host.lowercased() == lowered })
    }

    private static func normalizedForBench(_ device: Device) -> Device {
        guard device.port == 80 else { return device }
        switch device.kvmType {
        case .appleScreenSharing, .vnc:
            var copy = device
            copy.port = 5900
            return copy
        default:
            return device
        }
    }
}

enum DeviceSelectorError: Error, LocalizedError {
    case deviceNotFound(String)
    case wrongKVMType(got: Device.KVMType, expected: String)
    case noTTY

    var errorDescription: String? {
        switch self {
        case .deviceNotFound(let identifier):
            return "No saved device matched '\(identifier)'. Run `LatencyBench list` to see options."
        case .wrongKVMType(let got, let expected):
            return "Device kvmType '\(got.displayName)' is not in the allowed set [\(expected)]."
        case .noTTY:
            return "No interactive terminal available; pass --device <name> or set a password."
        }
    }
}
#endif
