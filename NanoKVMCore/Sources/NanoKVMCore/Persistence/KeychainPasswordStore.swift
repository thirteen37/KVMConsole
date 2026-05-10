import Foundation
import Security

public enum KeychainPasswordStoreError: Error, LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status): return "Keychain returned status \(status)."
        case .invalidData: return "Keychain returned invalid password data."
        }
    }
}

public protocol PasswordStore: Sendable {
    func password(for account: String) throws -> String?
    func savePassword(_ password: String, for account: String) throws
    func deletePassword(for account: String) throws
}

public struct KeychainPasswordAccount: Equatable, Sendable {
    public let scheme: Device.Scheme
    public let host: String
    public let port: Int
    public let username: String

    public init(scheme: Device.Scheme, host: String, port: Int, username: String) {
        self.scheme = scheme
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.port = port
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var rawValue: String {
        "\(scheme.rawValue)://\(host):\(port)#\(username)"
    }
}

public struct KeychainPasswordStore: PasswordStore {
    public static let service = "io.lyx.NanoKVM.device-password"

    private let service: String

    public init(service: String = Self.service) {
        self.service = service
    }

    public func password(for account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainPasswordStoreError.unexpectedStatus(status)
        }
        guard
            let data = result as? Data,
            let password = String(data: data, encoding: .utf8)
        else {
            throw KeychainPasswordStoreError.invalidData
        }
        return password
    }

    public func savePassword(_ password: String, for account: String) throws {
        let data = Data(password.utf8)
        var query = baseQuery(account: account)

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainPasswordStoreError.unexpectedStatus(updateStatus)
        }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainPasswordStoreError.unexpectedStatus(addStatus)
        }
    }

    public func deletePassword(for account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainPasswordStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
