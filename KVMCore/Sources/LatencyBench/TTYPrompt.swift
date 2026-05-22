#if os(macOS)
import Darwin
import Foundation
import KVMCore

enum TTYPrompt {
    static func promptLine(_ prompt: String, default defaultValue: String? = nil) -> String {
        if let defaultValue, !defaultValue.isEmpty {
            FileHandle.standardError.write(Data("\(prompt) [\(defaultValue)]: ".utf8))
        } else {
            FileHandle.standardError.write(Data("\(prompt): ".utf8))
        }
        guard let line = readLine(strippingNewline: true) else { return defaultValue ?? "" }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty, let defaultValue { return defaultValue }
        return trimmed
    }

    static func promptInt(_ prompt: String, default defaultValue: Int?) -> Int? {
        while true {
            let value = promptLine(prompt, default: defaultValue.map(String.init))
            if value.isEmpty { return defaultValue }
            if let parsed = Int(value) { return parsed }
            FileHandle.standardError.write(Data("Not a valid integer. Try again.\n".utf8))
        }
    }

    static func promptChoice<Choice>(
        _ prompt: String,
        choices: [(label: String, value: Choice)],
        defaultIndex: Int = 0
    ) -> Choice {
        FileHandle.standardError.write(Data("\(prompt)\n".utf8))
        for (index, choice) in choices.enumerated() {
            let marker = index == defaultIndex ? "*" : " "
            FileHandle.standardError.write(Data("  \(marker) \(index + 1). \(choice.label)\n".utf8))
        }
        while true {
            let raw = promptLine("Enter choice", default: String(defaultIndex + 1))
            if let n = Int(raw), n >= 1, n <= choices.count {
                return choices[n - 1].value
            }
            FileHandle.standardError.write(Data("Not in range.\n".utf8))
        }
    }

    /// Reads a password from the TTY without echoing.
    static func promptForPassword(prompt: String) -> String {
        guard let cString = getpass(prompt) else { return "" }
        defer { _ = memset(UnsafeMutableRawPointer(mutating: cString), 0, strlen(cString)) }
        return String(cString: cString)
    }

    static func promptForDevice(existing: [Device]) throws -> Device {
        if !existing.isEmpty {
            FileHandle.standardError.write(Data("Saved devices:\n".utf8))
            for (index, device) in existing.enumerated() {
                FileHandle.standardError.write(Data("  \(index + 1). \(describe(device))\n".utf8))
            }
            FileHandle.standardError.write(Data("  N. Enter a new device\n".utf8))
            let raw = promptLine("Choose a device", default: "1")
            if let n = Int(raw), n >= 1, n <= existing.count {
                return existing[n - 1]
            }
        } else {
            FileHandle.standardError.write(Data("No saved devices found. Define one for this run.\n".utf8))
        }

        let name = promptLine("Device name", default: "ad-hoc")
        let host = promptLine("Host", default: nil)
        guard !host.isEmpty else { throw DeviceSelectorError.deviceNotFound("(blank host)") }
        let username = promptLine("Username", default: "admin")
        let kvmType = promptChoice(
            "KVM type",
            choices: Device.KVMType.allCases.map { ($0.displayName, $0) },
            defaultIndex: Device.KVMType.allCases.firstIndex(of: .appleScreenSharing) ?? 0
        )
        let defaultPort: Int
        switch kvmType {
        case .appleScreenSharing, .vnc: defaultPort = 5900
        default: defaultPort = 80
        }
        let port = promptInt("Port", default: defaultPort) ?? defaultPort
        let scheme: Device.Scheme = {
            switch kvmType {
            case .appleScreenSharing, .vnc: return .http
            case .comet: return .https
            default: return .http
            }
        }()
        return Device(
            name: name,
            host: host,
            port: port,
            scheme: scheme,
            username: username,
            kvmType: kvmType
        )
    }

    static func describe(_ device: Device) -> String {
        "\(device.name) — \(device.kvmType.displayName) @ \(device.host):\(device.port) (\(device.username))"
    }
}
#endif
