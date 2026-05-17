import Foundation

public enum H264StreamError: Error, LocalizedError, Equatable {
    case invalidURL
    case frameTooShort
    case emptyPayload
    case unsupportedMessage

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid H.264 stream URL."
        case .frameTooShort: return "H.264 stream frame is shorter than the 9-byte header."
        case .emptyPayload: return "H.264 stream frame has no video payload."
        case .unsupportedMessage: return "H.264 stream returned a non-binary message."
        }
    }
}

public struct H264StreamFrame: Equatable, Sendable {
    public let isKeyFrame: Bool
    public let timestampMicros: UInt64
    public let payload: Data

    public init(isKeyFrame: Bool, timestampMicros: UInt64, payload: Data) {
        self.isKeyFrame = isKeyFrame
        self.timestampMicros = timestampMicros
        self.payload = payload
    }
}

public enum H264StreamFrameParser {
    public static func parse(_ data: Data) throws -> H264StreamFrame {
        guard data.count >= 9 else { throw H264StreamError.frameTooShort }

        let bytes = [UInt8](data.prefix(9))
        let timestamp = bytes[1..<9].enumerated().reduce(UInt64(0)) { partial, item in
            partial | (UInt64(item.element) << UInt64(item.offset * 8))
        }
        let payload = data.dropFirst(9)
        guard !payload.isEmpty else { throw H264StreamError.emptyPayload }

        return H264StreamFrame(
            isKeyFrame: bytes[0] == 1,
            timestampMicros: timestamp,
            payload: Data(payload)
        )
    }
}

public final class H264StreamSocket: @unchecked Sendable {
    private let device: Device
    private let token: String
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    public init(device: Device, token: String, session: URLSession = .shared) {
        self.device = device
        self.token = token
        self.session = session
    }

    public func frames() throws -> AsyncThrowingStream<H264StreamFrame, Error> {
        guard let url = streamURL else { throw H264StreamError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("nano-kvm-token=\(token)", forHTTPHeaderField: "Cookie")

        let webSocketTask = session.webSocketTask(with: request)
        task = webSocketTask

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            webSocketTask.resume()
            let receiveTask = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await webSocketTask.receive()
                        switch message {
                        case .data(let data):
                            do {
                                continuation.yield(try H264StreamFrameParser.parse(data))
                            } catch H264StreamError.frameTooShort, H264StreamError.emptyPayload {
                                continue
                            }
                        case .string:
                            throw H264StreamError.unsupportedMessage
                        @unknown default:
                            throw H264StreamError.unsupportedMessage
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

            continuation.onTermination = { @Sendable _ in
                receiveTask.cancel()
                webSocketTask.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    public func cancel() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private var streamURL: URL? {
        var components = URLComponents()
        components.scheme = device.webSocketScheme
        components.host = device.host
        let isDefaultPort = (device.scheme == .http && device.port == 80) || (device.scheme == .https && device.port == 443)
        if !isDefaultPort {
            components.port = device.port
        }
        components.path = "/api/stream/h264/direct"
        return components.url
    }
}
