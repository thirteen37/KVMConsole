@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation
import QuartzCore

public final class SampleBufferDisplay {
    public let layer: AVSampleBufferDisplayLayer

    public init() {
        layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.masksToBounds = true
    }

    public func setVideoTransform(_ transform: CGAffineTransform) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(transform)
        CATransaction.commit()
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

public final class SampleBufferRenderCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private weak var display: SampleBufferDisplay?
    private var lastPresentationTime: CMTime?

    public init() {}

    public func attach(display: SampleBufferDisplay) {
        lock.lock()
        let displayChanged = self.display !== display
        if displayChanged {
            self.display = display
            lastPresentationTime = nil
        }
        lock.unlock()

        if displayChanged {
            display.flush()
        }
    }

    public func detach(display: SampleBufferDisplay) {
        lock.lock()
        if self.display === display {
            self.display = nil
            lastPresentationTime = nil
        }
        lock.unlock()
    }

    public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        lock.lock()
        guard shouldAccept(presentationTime: presentationTime) else {
            lock.unlock()
            return
        }
        lastPresentationTime = presentationTime
        let display = display
        lock.unlock()

        display?.enqueue(sampleBuffer)
    }

    public func flush() {
        lock.lock()
        lastPresentationTime = nil
        let display = display
        lock.unlock()

        display?.flush()
    }

    private func shouldAccept(presentationTime: CMTime) -> Bool {
        guard let lastPresentationTime else { return true }
        return CMTimeCompare(presentationTime, lastPresentationTime) > 0
    }
}
