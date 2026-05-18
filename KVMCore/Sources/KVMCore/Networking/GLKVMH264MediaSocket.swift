import Foundation

public enum GLKVMH264MediaError: Error, LocalizedError, Equatable {
    case invalidURL
    case unsupportedMessage
    case h264Unavailable
    case frameTooShort
    case emptyPayload

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid GLKVM media socket URL."
        case .unsupportedMessage:
            return "GLKVM media socket returned an unsupported message."
        case .h264Unavailable:
            return "GLKVM did not advertise a direct H.264 stream."
        case .frameTooShort:
            return "GLKVM direct H.264 frame is shorter than the 2-byte header."
        case .emptyPayload:
            return "GLKVM direct H.264 frame has no video payload."
        }
    }
}

public enum GLKVMDirectH264FrameParser {
    public static func parse(_ data: Data, timestampMicros: UInt64) throws -> H264StreamFrame? {
        guard let kind = data.first else { throw GLKVMH264MediaError.frameTooShort }
        if kind == 0xff {
            return nil
        }
        guard kind == 0x01 else { throw GLKVMH264MediaError.unsupportedMessage }
        guard data.count >= 2 else { throw GLKVMH264MediaError.frameTooShort }

        let bytes = [UInt8](data.prefix(2))
        let payload = data.dropFirst(2)
        guard !payload.isEmpty else { throw GLKVMH264MediaError.emptyPayload }

        return H264StreamFrame(
            isKeyFrame: bytes[1] != 0,
            timestampMicros: timestampMicros,
            payload: Data(payload)
        )
    }
}

public final class GLKVMH264MediaSocket: @unchecked Sendable {
    private let device: Device
    private let authToken: String
    private let session: URLSession
    private let ownedSession: URLSession?
    private var task: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?
    private var firstFrameLogged = false

    public init(device: Device, authToken: String, session: URLSession? = nil) {
        self.device = device
        self.authToken = authToken
        if let session {
            self.session = session
            self.ownedSession = nil
        } else if device.allowsInsecureTLS {
            let delegate = InsecureTLSDelegate()
            let owned = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            self.session = owned
            self.ownedSession = owned
        } else {
            self.session = URLSession.shared
            self.ownedSession = nil
        }
    }

    public func frames() throws -> AsyncThrowingStream<H264StreamFrame, Error> {
        guard let url = mediaURL else { throw GLKVMH264MediaError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("auth_token=\(authToken)", forHTTPHeaderField: "Cookie")
        KVMLog.glkvm.info("Opening GLKVM direct H.264 media WebSocket: \(url.absoluteString, privacy: .public)")

        let webSocketTask = session.webSocketTask(with: request)
        webSocketTask.priority = URLSessionTask.highPriority
        task = webSocketTask

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            webSocketTask.resume()
            startHeartbeat(task: webSocketTask)

            let receiveTask = Task { [weak self] in
                var nextSequenceNumber: UInt64 = 0
                do {
                    while !Task.isCancelled {
                        let message = try await webSocketTask.receive()
                        switch message {
                        case .string(let text):
                            try await self?.handle(text: text, task: webSocketTask)
                        case .data(let data):
                            guard let self else { continue }
                            let timestamp = DispatchTime.now().uptimeNanoseconds / 1_000
                            if let frame = try GLKVMDirectH264FrameParser.parse(data, timestampMicros: timestamp) {
                                self.logFirstFrameIfNeeded(frame)
                                continuation.yield(H264StreamFrame(
                                    isKeyFrame: frame.isKeyFrame,
                                    timestampMicros: frame.timestampMicros,
                                    payload: frame.payload,
                                    sequenceNumber: nextSequenceNumber
                                ))
                                nextSequenceNumber &+= 1
                            }
                        @unknown default:
                            throw GLKVMH264MediaError.unsupportedMessage
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }

            continuation.onTermination = { @Sendable [weak self] _ in
                receiveTask.cancel()
                self?.cancel()
            }
        }
    }

    public func cancel() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        firstFrameLogged = false
        ownedSession?.invalidateAndCancel()
    }

    private func startHeartbeat(task: URLSessionWebSocketTask) {
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                try? await task.send(.data(Data([0x00])))
            }
        }
    }

    private func handle(text: String, task: URLSessionWebSocketTask) async throws {
        guard
            let data = text.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let eventType = object["event_type"] as? String
        else {
            throw GLKVMH264MediaError.unsupportedMessage
        }

        guard eventType == "media" else { return }
        guard
            let event = object["event"] as? [String: Any],
            let video = event["video"] as? [String: Any],
            let h264 = video["h264"] as? [String: Any]
        else {
            throw GLKVMH264MediaError.h264Unavailable
        }

        KVMLog.glkvm.info("GLKVM direct media advertised H.264 profile=\(String(describing: h264["profile_level_id"]), privacy: .public)")
        try await task.send(.string(#"{"event_type":"start","event":{"type":"video","format":"h264"}}"#))
    }

    private func logFirstFrameIfNeeded(_ frame: H264StreamFrame) {
        guard !firstFrameLogged else { return }
        firstFrameLogged = true
        let prefix = frame.payload.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
        KVMLog.glkvm.info(
            "GLKVM direct H.264 first frame: key=\(frame.isKeyFrame, privacy: .public) bytes=\(frame.payload.count, privacy: .public) prefix=\(prefix, privacy: .public)"
        )
    }

    private var mediaURL: URL? {
        var components = URLComponents()
        components.scheme = device.webSocketScheme
        components.host = device.host
        let isDefaultPort = (device.scheme == .http && device.port == 80) || (device.scheme == .https && device.port == 443)
        if !isDefaultPort {
            components.port = device.port
        }
        components.path = "/api/media/ws"
        return components.url
    }
}
