import Foundation

public struct Device: Identifiable, Hashable, Codable, Sendable {
    public enum Scheme: String, Codable, Sendable { case http, https }

    public let id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var scheme: Scheme
    public var username: String

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int? = nil,
        scheme: Scheme = .http,
        username: String = "admin"
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port ?? (scheme == .https ? 443 : 80)
        self.scheme = scheme
        self.username = username
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
