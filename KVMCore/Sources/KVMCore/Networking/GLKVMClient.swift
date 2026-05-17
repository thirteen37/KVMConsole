import Foundation

public enum GLKVMError: Error, LocalizedError, Equatable {
    case invalidURL
    case unexpectedStatus(Int)
    case missingAuthToken
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid GLKVM URL."
        case .unexpectedStatus(let code): return "GLKVM returned HTTP \(code)."
        case .missingAuthToken: return "GLKVM did not return an auth cookie."
        case .decodingFailed(let message): return "GLKVM decoding failed: \(message)"
        }
    }
}

public actor GLKVMClient: KVMPowerControl {
    public enum ATXPowerAction: String, Sendable {
        case on
        case off
        case forceOff = "off_hard"
        case reset = "reset_hard"
    }

    public enum ATXClickButton: String, Sendable {
        case power
        case powerLong = "power_long"
        case reset
    }

    public let device: Device
    private let session: URLSessionProtocol
    public private(set) var authToken: String?

    public init(device: Device, session: URLSessionProtocol? = nil) {
        self.device = device
        if let session {
            self.session = session
        } else if device.allowsInsecureTLS {
            let delegate = InsecureTLSDelegate(allowsInsecureTLS: true)
            self.session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        } else {
            self.session = URLSession.shared
        }
    }

    public func setAuthToken(_ token: String?) {
        authToken = token
    }

    public func login(password: String) async throws {
        guard let url = url(path: "/api/auth/login") else { throw GLKVMError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formEncoded([
            "user": device.username,
            "passwd": password,
        ])

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GLKVMError.unexpectedStatus(-1) }
        guard (200..<300).contains(http.statusCode) else { throw GLKVMError.unexpectedStatus(http.statusCode) }
        guard let token = Self.authToken(from: http) else { throw GLKVMError.missingAuthToken }
        authToken = token
    }

    public func info() async throws -> GLKVMInfo {
        try await getJSON(path: "/api/info")
    }

    public func atxPower(_ action: ATXPowerAction) async throws {
        try await postNoBody(path: "/api/atx/power", queryItems: [
            URLQueryItem(name: "action", value: action.rawValue),
        ])
    }

    public func atxClick(_ button: ATXClickButton) async throws {
        try await postNoBody(path: "/api/atx/click", queryItems: [
            URLQueryItem(name: "button", value: button.rawValue),
        ])
    }

    public func setStreamerVideoFormatH264() async throws {
        try await postNoBody(path: "/api/streamer/set_params", queryItems: [
            URLQueryItem(name: "video_format", value: "0"),
        ])
    }

    public func powerOn() async throws { try await atxPower(.on) }
    public func powerOff() async throws { try await atxPower(.off) }
    public func forceOff() async throws { try await atxPower(.forceOff) }
    public func reset() async throws { try await atxPower(.reset) }
    public func longPressPower() async throws { try await atxClick(.powerLong) }

    private func getJSON<T: Decodable>(path: String) async throws -> T {
        guard let url = url(path: path) else { throw GLKVMError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        addAuth(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GLKVMError.unexpectedStatus(-1) }
        guard (200..<300).contains(http.statusCode) else { throw GLKVMError.unexpectedStatus(http.statusCode) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GLKVMError.decodingFailed(String(describing: error))
        }
    }

    private func postNoBody(path: String, queryItems: [URLQueryItem]) async throws {
        guard let url = url(path: path, queryItems: queryItems) else { throw GLKVMError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        addAuth(to: &request)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GLKVMError.unexpectedStatus(-1) }
        guard (200..<300).contains(http.statusCode) else { throw GLKVMError.unexpectedStatus(http.statusCode) }
    }

    private func addAuth(to request: inout URLRequest) {
        guard let authToken else { return }
        request.setValue("auth_token=\(authToken)", forHTTPHeaderField: "Cookie")
    }

    private func url(path: String, queryItems: [URLQueryItem] = []) -> URL? {
        guard let baseURL = device.baseURL else { return nil }
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        return components?.url
    }

    private func formEncoded(_ fields: [String: String]) -> Data {
        let body = fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func authToken(from response: HTTPURLResponse) -> String? {
        let header = response.allHeaderFields.first { key, _ in
            (key as? String)?.caseInsensitiveCompare("Set-Cookie") == .orderedSame
        }?.value as? String
        guard let header else { return nil }
        return header
            .split(separator: ";", omittingEmptySubsequences: true)
            .lazy
            .compactMap { part -> String? in
                let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == "auth_token" else {
                    return nil
                }
                return String(pair[1])
            }
            .first
    }
}

public struct GLKVMInfo: Decodable, Sendable, Equatable {
    public let hostname: String?
    public let kvmd: [String: String]?
    public let streamer: [String: String]?
}
