import Foundation

public struct Device: Identifiable, Hashable, Codable, Sendable {
    public enum Scheme: String, Codable, Sendable { case http, https }
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case nanoKVM
        case glkvm

        public var displayName: String {
            switch self {
            case .nanoKVM: return "NanoKVM"
            case .glkvm: return "GLKVM (Comet GL-RM1)"
            }
        }
    }

    public let id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var scheme: Scheme
    public var username: String
    public var kind: Kind
    public var allowsInsecureTLS: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int? = nil,
        scheme: Scheme = .http,
        username: String = "admin",
        kind: Kind = .nanoKVM,
        allowsInsecureTLS: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port ?? (scheme == .https ? 443 : 80)
        self.scheme = scheme
        self.username = username
        self.kind = kind
        self.allowsInsecureTLS = allowsInsecureTLS ?? (kind == .glkvm)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case port
        case scheme
        case username
        case kind
        case allowsInsecureTLS
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        scheme = try container.decode(Scheme.self, forKey: .scheme)
        username = try container.decode(String.self, forKey: .username)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .nanoKVM
        allowsInsecureTLS = try container.decodeIfPresent(Bool.self, forKey: .allowsInsecureTLS) ?? (kind == .glkvm)
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
