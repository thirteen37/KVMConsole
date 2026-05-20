@preconcurrency import AVFAudio
import Foundation

public final class RFBAudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var format: AVAudioFormat?

    public init() {
        engine.attach(playerNode)
    }

    public func start(format: AVAudioFormat) throws {
        stop()
        self.format = format
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        try engine.start()
        playerNode.play()
    }

    public func scheduleBuffer(_ buffer: AVAudioPCMBuffer) {
        guard engine.isRunning else { return }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    public func stop() {
        playerNode.stop()
        engine.stop()
        engine.reset()
        format = nil
    }
}
