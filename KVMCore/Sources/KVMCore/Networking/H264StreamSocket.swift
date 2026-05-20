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
    public let sequenceNumber: UInt64

    public init(isKeyFrame: Bool, timestampMicros: UInt64, payload: Data, sequenceNumber: UInt64 = 0) {
        self.isKeyFrame = isKeyFrame
        self.timestampMicros = timestampMicros
        self.payload = payload
        self.sequenceNumber = sequenceNumber
    }
}

enum H264StreamBuffering {
    static let frameLimit = 12
}

struct H264StreamFrameSequencer {
    private var nextSequenceNumber: UInt64 = 0
    private var droppedFrameCount: UInt64 = 0
    private let source: String

    init(source: String) {
        self.source = source
    }

    mutating func nextFrame(from frame: H264StreamFrame) -> H264StreamFrame {
        defer { nextSequenceNumber &+= 1 }
        return H264StreamFrame(
            isKeyFrame: frame.isKeyFrame,
            timestampMicros: frame.timestampMicros,
            payload: frame.payload,
            sequenceNumber: nextSequenceNumber
        )
    }

    mutating func recordYield(_ result: AsyncThrowingStream<H264StreamFrame, Error>.Continuation.YieldResult) {
        guard case .dropped(let droppedFrame) = result else { return }

        droppedFrameCount &+= 1
        guard droppedFrameCount <= 5 || droppedFrameCount.isMultiple(of: 30) else { return }

        let source = source
        let totalDropped = droppedFrameCount
        KVMLog.video.info(
            "H.264 stream buffer dropped frame source=\(source, privacy: .public) appSequence=\(droppedFrame.sequenceNumber, privacy: .public) totalDropped=\(totalDropped, privacy: .public)"
        )
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

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(H264StreamBuffering.frameLimit)) { continuation in
            webSocketTask.resume()
            let receiveTask = Task {
                var frameSequencer = H264StreamFrameSequencer(source: "NanoKVM H.264")
                do {
                    while !Task.isCancelled {
                        let message = try await webSocketTask.receive()
                        switch message {
                        case .data(let data):
                            do {
                                let frame = try H264StreamFrameParser.parse(data)
                                frameSequencer.recordYield(continuation.yield(frameSequencer.nextFrame(from: frame)))
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
