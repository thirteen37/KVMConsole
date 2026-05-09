import Foundation

struct Device: Identifiable, Hashable, Codable, Sendable {
    enum Scheme: String, Codable, Sendable { case http, https }

    let id: UUID
    var name: String
    var host: String
    var port: Int
    var scheme: Scheme
    var username: String

    init(
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

    var baseURL: URL? {
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = host
        let isDefaultPort = (scheme == .http && port == 80) || (scheme == .https && port == 443)
        if !isDefaultPort {
            components.port = port
        }
        return components.url
    }

    var webSocketScheme: String { scheme == .https ? "wss" : "ws" }
}
