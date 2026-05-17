import Foundation

public struct Device: Identifiable, Hashable, Codable, Sendable {
    public enum Scheme: String, Codable, Sendable { case http, https }

    public enum KVMType: String, Codable, Sendable, CaseIterable {
        case nanoKVMLite
        case nanoKVMUSB
        case comet
        case appleRFB

        public var displayName: String {
            switch self {
            case .nanoKVMLite: return "NanoKVM Lite"
            case .nanoKVMUSB: return "NanoKVM USB"
            case .comet: return "GL.iNet Comet"
            case .appleRFB: return "Apple Screen Sharing"
            }
        }

        public enum IconSource: Sendable {
            case systemSymbol(String)
            case bundledAsset(String)
        }

        public var iconSource: IconSource {
            switch self {
            case .nanoKVMLite, .nanoKVMUSB: return .bundledAsset("sipeed")
            case .comet: return .systemSymbol("wifi.router")
            case .appleRFB: return .systemSymbol("apple.logo")
            }
        }
    }

    public let id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var scheme: Scheme
    public var username: String
    public var kvmType: KVMType
    public var lastConnectedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int? = nil,
        scheme: Scheme = .http,
        username: String = "admin",
        kvmType: KVMType = .nanoKVMUSB,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port ?? (scheme == .https ? 443 : 80)
        self.scheme = scheme
        self.username = username
        self.kvmType = kvmType
        self.lastConnectedAt = lastConnectedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.host = try container.decode(String.self, forKey: .host)
        self.port = try container.decode(Int.self, forKey: .port)
        self.scheme = try container.decode(Scheme.self, forKey: .scheme)
        self.username = try container.decode(String.self, forKey: .username)
        self.kvmType = try container.decodeIfPresent(KVMType.self, forKey: .kvmType) ?? .nanoKVMUSB
        self.lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
    }

    public var baseURL: URL? {
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = host
        let isDefaultPort = (scheme == .http && port == 80) || (scheme == .https && port == 443)
        if !isDefaultPort {
            components.port = port
        }
        return components.url
    }

    public var webSocketScheme: String { scheme == .https ? "wss" : "ws" }
}
