@preconcurrency import AVFAudio
import Foundation

public enum RFBAppleAudioChannelError: Error, LocalizedError, Equatable {
    case unsupportedFormat
    case malformedFrame

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Unsupported Apple Screen Sharing audio format."
        case .malformedFrame:
            return "Malformed Apple Screen Sharing audio frame."
        }
    }
}

public final class RFBAppleAudioChannel: @unchecked Sendable {
    private let player: RFBAudioPlayer
    private var format: AVAudioFormat?

    public init(player: RFBAudioPlayer = RFBAudioPlayer()) {
        self.player = player
    }

    public func startPCM(sampleRate: Double, channels: AVAudioChannelCount) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            throw RFBAppleAudioChannelError.unsupportedFormat
        }
        self.format = format
        try player.start(format: format)
    }

    public func scheduleFloat32PCM(_ data: Data, frameCount: AVAudioFrameCount) throws {
        guard let format else {
            throw RFBAppleAudioChannelError.unsupportedFormat
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw RFBAppleAudioChannelError.malformedFrame
        }
        buffer.frameLength = frameCount

        let channels = Int(format.channelCount)
        let expectedByteCount = Int(frameCount) * channels * MemoryLayout<Float>.size
        guard data.count == expectedByteCount, let channelData = buffer.floatChannelData else {
            throw RFBAppleAudioChannelError.malformedFrame
        }

        data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            for frame in 0..<Int(frameCount) {
                for channel in 0..<channels {
                    channelData[channel][frame] = source[frame * channels + channel]
                }
            }
        }
        player.scheduleBuffer(buffer)
    }

    public func stop() {
        player.stop()
        format = nil
    }
}
