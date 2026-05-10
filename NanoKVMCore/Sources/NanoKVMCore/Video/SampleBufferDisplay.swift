@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import QuartzCore

public final class SampleBufferDisplay {
    public let layer: AVSampleBufferDisplayLayer

    public init() {
        layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if layer.status == .failed {
            layer.flush()
        }
        layer.enqueue(sampleBuffer)
    }

    public func flush() {
        layer.flushAndRemoveImage()
    }
}

public final class SampleBufferRenderCoordinator {
    public var lastFlushToken: Int = 0
    public var lastPresentationTime: CMTime?

    public init() {}

    public func update(sampleBuffer: CMSampleBuffer?, flushToken: Int, display: SampleBufferDisplay) {
        if lastFlushToken != flushToken {
            lastFlushToken = flushToken
            lastPresentationTime = nil
            display.flush()
        }

        guard let sampleBuffer else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard lastPresentationTime != presentationTime else { return }
        lastPresentationTime = presentationTime
        display.enqueue(sampleBuffer)
    }
}
