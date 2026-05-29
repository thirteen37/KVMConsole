import Foundation

public struct Device: Identifiable, Hashable, Codable, Sendable {
    public enum Scheme: String, Codable, Sendable { case http, https }

    public enum KVMType: String, Codable, Sendable, CaseIterable {
        case nanoKVMLite
        case nanoKVMUSB
        case comet
        case appleScreenSharing
        case vnc

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            if rawValue == "appleRFB" {
                self = .appleScreenSharing
                return
            }
            guard let value = Self(rawValue: rawValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid KVM type '\(rawValue)'"
                )
            }
            self = value
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        public var displayName: String {
            switch self {
            case .nanoKVMLite: return "NanoKVM Lite"
            case .nanoKVMUSB: return "NanoKVM USB"
            case .comet: return "GL.iNet Comet"
            case .appleScreenSharing: return "Apple Screen Sharing"
            case .vnc: return "VNC"
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
            case .appleScreenSharing: return .systemSymbol("apple.logo")
            case .vnc: return .systemSymbol("network")
            }
        }

        /// Device types that should appear in the device-editor type picker on the
        /// current platform. `.nanoKVMUSB` is a USB-attached capture stick (UVC video +
        /// CH9329 serial), so it is hidden on iPadOS, where there is no public USB-serial
        /// API. `.nanoKVMLite` is an IP-based NanoKVM and remains available everywhere.
        public static var userVisibleCases: [KVMType] {
            #if os(macOS)
            return allCases
            #else
            return allCases.filter { $0 != .nanoKVMUSB }
            #endif
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
    public var videoDeviceUniqueID: String?
    public var serialDevicePath: String?

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int? = nil,
        scheme: Scheme = .http,
        username: String = "admin",
        kvmType: KVMType = .nanoKVMLite,
        allowsInsecureTLS: Bool? = nil,
        lastConnectedAt: Date? = nil,
        videoDeviceUniqueID: String? = nil,
        serialDevicePath: String? = nil
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
        self.videoDeviceUniqueID = videoDeviceUniqueID
        self.serialDevicePath = serialDevicePath
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
        case videoDeviceUniqueID
        case serialDevicePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        scheme = try container.decode(Scheme.self, forKey: .scheme)
        username = try container.decode(String.self, forKey: .username)
        kvmType = try container.decodeIfPresent(KVMType.self, forKey: .kvmType) ?? .nanoKVMLite
        allowsInsecureTLS = try container.decodeIfPresent(Bool.self, forKey: .allowsInsecureTLS) ?? (kvmType == .comet)
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        videoDeviceUniqueID = try container.decodeIfPresent(String.self, forKey: .videoDeviceUniqueID)
        serialDevicePath = try container.decodeIfPresent(String.self, forKey: .serialDevicePath)

        // On origin/main `.nanoKVMUSB` was the IP-based NanoKVM type; this branch
        // repurposed it for the local Sipeed USB capture stick. Remap legacy entries —
        // identifiable by a host and no USB device fields — back to `.nanoKVMLite` so
        // they keep routing to NanoKVMSession instead of failing as a USB device.
        if kvmType == .nanoKVMUSB, videoDeviceUniqueID == nil, serialDevicePath == nil, !host.isEmpty {
            kvmType = .nanoKVMLite
        }
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
