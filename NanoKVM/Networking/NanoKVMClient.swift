import Foundation

enum NanoKVMError: Error, LocalizedError, Equatable {
    case invalidURL
    case unexpectedStatus(Int)
    case serverError(code: Int, message: String)
    case decodingFailed(String)
    case missingToken

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL."
        case .unexpectedStatus(let code): return "Server returned HTTP \(code)."
        case .serverError(let code, let message): return "NanoKVM error \(code): \(message)"
        case .decodingFailed(let s): return "Decoding failed: \(s)"
        case .missingToken: return "Not authenticated."
        }
    }
}

/// REST client for the subset of NanoKVM endpoints this app uses.
///
/// All NanoKVM responses follow `{code: Int, msg: String, data: T}` where
/// `code == 0` means success. Field names in request bodies are lowerCamelCase
/// JSON; the Gin backend's case-insensitive JSON binder accepts them.
actor NanoKVMClient {
    let device: Device
    private let session: URLSessionProtocol
    private(set) var token: String?

    init(device: Device, session: URLSessionProtocol = URLSession.shared) {
        self.device = device
        self.session = session
    }

    func setToken(_ token: String?) { self.token = token }

    // MARK: - Endpoints

    func login(password: String) async throws {
        struct Req: Encodable { let username: String; let password: String }
        struct Rsp: Decodable { let token: String }
        let encryptedPassword = try NanoKVMPasswordEncryptor.encrypt(password)
        let rsp: Rsp = try await post("/api/auth/login", Req(username: device.username, password: encryptedPassword), authenticated: false)
        guard !rsp.token.isEmpty else { throw NanoKVMError.serverError(code: -1, message: "empty token") }
        self.token = rsp.token
    }

    func vmInfo() async throws -> VMInfo {
        try await get("/api/vm/info")
    }

    /// Switch the device into H.264 mode. The server's `vm/screen` endpoint takes
    /// `type` ("type" | "fps" | "quality" | "resolution" | "gop") and `value`. To
    /// select the codec, send `type:"type"` with `value:1` (h264) or `value:0` (mjpeg).
    func selectH264() async throws {
        try await postNoData("/api/vm/screen", ScreenReq(type: "type", value: 1))
    }

    /// Type a string into the remote machine via the HID paste endpoint.
    /// Limit: server enforces ~1024 chars; ~30ms per keystroke.
    func paste(_ content: String, language: String = "en") async throws {
        try await postNoData("/api/hid/paste", PasteReq(content: content, langue: language))
    }

    // MARK: - HTTP plumbing

    private struct Envelope<T: Decodable>: Decodable {
        let code: Int
        let msg: String
        let data: T?
    }

    private struct Empty: Decodable {}
    private struct ScreenReq: Encodable { let type: String; let value: Int }
    private struct PasteReq: Encodable { let content: String; let langue: String }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await send(method: "GET", path: path, body: nil, authenticated: true)
    }

    private func post<Body: Encodable, T: Decodable>(_ path: String, _ body: Body, authenticated: Bool = true) async throws -> T {
        let data = try JSONEncoder().encode(body)
        return try await send(method: "POST", path: path, body: data, authenticated: authenticated)
    }

    private func postNoData<Body: Encodable>(_ path: String, _ body: Body) async throws {
        let _: Empty = try await post(path, body)
    }

    private func send<T: Decodable>(method: String, path: String, body: Data?, authenticated: Bool) async throws -> T {
        guard let url = URL(string: path, relativeTo: device.baseURL) else { throw NanoKVMError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        if authenticated {
            guard let token else { throw NanoKVMError.missingToken }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("nano-kvm-token=\(token)", forHTTPHeaderField: "Cookie")
        }

        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NanoKVMError.unexpectedStatus(-1) }
        guard (200..<300).contains(http.statusCode) else { throw NanoKVMError.unexpectedStatus(http.statusCode) }

        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: responseData)
        } catch {
            throw NanoKVMError.decodingFailed(String(describing: error))
        }
        if envelope.code != 0 {
            throw NanoKVMError.serverError(code: envelope.code, message: envelope.msg)
        }
        if let data = envelope.data { return data }
        // Endpoints that return no data (`OkRsp`) — synthesize an empty value of T.
        if let empty = Empty() as? T { return empty }
        throw NanoKVMError.decodingFailed("envelope has no `data` for required type \(T.self)")
    }
}

// MARK: - Response models

struct VMInfo: Decodable, Sendable, Equatable {
    struct IP: Decodable, Sendable, Equatable {
        let name: String
        let addr: String
        let version: String
        let type: String
    }
    let ips: [IP]
    let mdns: String
    let image: String?
    let application: String?
    let deviceKey: String?
}

// MARK: - URLSession seam for tests

protocol URLSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}
