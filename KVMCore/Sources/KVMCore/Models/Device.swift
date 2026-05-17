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
            case .comet: return .bundledAsset("glinet")
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
    public var allowsInsecureTLS: Bool
    public var lastConnectedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int? = nil,
        scheme: Scheme = .http,
        username: String = "admin",
        kvmType: KVMType = .nanoKVMUSB,
        allowsInsecureTLS: Bool? = nil,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port ?? (scheme == .https ? 443 : 80)
        self.scheme = scheme
        self.username = username
        self.kvmType = kvmType
        self.allowsInsecureTLS = allowsInsecureTLS ?? (kvmType == .comet)
        self.lastConnectedAt = lastConnectedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case port
        case scheme
        case username
        case kvmType
        case allowsInsecureTLS
        case lastConnectedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        scheme = try container.decode(Scheme.self, forKey: .scheme)
        username = try container.decode(String.self, forKey: .username)
        kvmType = try container.decodeIfPresent(KVMType.self, forKey: .kvmType) ?? .nanoKVMUSB
        allowsInsecureTLS = try container.decodeIfPresent(Bool.self, forKey: .allowsInsecureTLS) ?? (kvmType == .comet)
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
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
