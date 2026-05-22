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

    @MainActor
    static func listSavedDevices() -> [Device] {
        SavedDevicesStore().devices
    }

    @MainActor
    static func resolve(identifier: String?, requireKVMType: Set<Device.KVMType>?) throws -> Selection {
        let store = SavedDevicesStore()
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

        return Selection(device: device, password: password, passwordAccount: account)
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
