@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation
import QuartzCore

public final class SampleBufferDisplay {
    public let layer: CALayer
    private let sampleLayer: AVSampleBufferDisplayLayer
    private var enqueuedCount = 0

    public init() {
        layer = CALayer()
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.masksToBounds = true
        layer.contentsGravity = .resizeAspect

        sampleLayer = AVSampleBufferDisplayLayer()
        sampleLayer.videoGravity = .resizeAspect
        sampleLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        sampleLayer.masksToBounds = true
        layer.addSublayer(sampleLayer)
    }

    public func setVideoTransform(_ transform: CGAffineTransform) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(transform)
        CATransaction.commit()
    }

    public func enqueue(_ sampleBuffer: CMSampleBuffer, renderMode: SampleBufferRenderMode = .sampleBuffer) {
        switch renderMode {
        case .sampleBuffer:
            enqueueSampleBuffer(sampleBuffer, flushQueuedFrames: false)
        case .sampleBufferFlushingQueuedFrames:
            enqueueSampleBuffer(sampleBuffer, flushQueuedFrames: true)
        case .directLatestFrame:
            enqueueDirectFrame(sampleBuffer)
        }
    }

    private func enqueueSampleBuffer(_ sampleBuffer: CMSampleBuffer, flushQueuedFrames: Bool) {
        if sampleLayer.status == .failed {
            KVMLog.video.error("Sample buffer display layer failed: \(String(describing: self.sampleLayer.error), privacy: .public)")
            sampleLayer.flush()
        }
        if flushQueuedFrames {
            sampleLayer.flush()
        }
        enqueuedCount += 1
        if enqueuedCount == 1 || enqueuedCount % 120 == 0 {
            KVMLog.video.info("Sample buffer display layer enqueue count: \(self.enqueuedCount, privacy: .public)")
        }
        let enqueue = { [sampleLayer, layer] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sampleLayer.isHidden = false
            sampleLayer.frame = layer.bounds
            layer.contents = nil
            CATransaction.commit()
            sampleLayer.enqueue(sampleBuffer)
        }
        if Thread.isMainThread {
            enqueue()
        } else {
            DispatchQueue.main.async(execute: enqueue)
        }
    }

    private func enqueueDirectFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let cgImage = makeOpaqueImage(from: imageBuffer) else { return }
        enqueuedCount += 1
        if enqueuedCount == 1 || enqueuedCount % 120 == 0 {
            KVMLog.video.info("Direct frame display count: \(self.enqueuedCount, privacy: .public)")
        }

        let display = { [layer, sampleLayer] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sampleLayer.flush()
            sampleLayer.isHidden = true
            sampleLayer.frame = layer.bounds
            layer.contents = cgImage
            CATransaction.commit()
        }
        if Thread.isMainThread {
            display()
        } else {
            DispatchQueue.main.async(execute: display)
        }
    }

    private func makeOpaqueImage(from pixelBuffer: CVImageBuffer) -> CGImage? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let destinationBytesPerRow = width * 4
        var data = Data(count: destinationBytesPerRow * height)

        data.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            for row in 0..<height {
                let source = baseAddress.advanced(by: row * sourceBytesPerRow)
                let rowDestination = destinationBase.advanced(by: row * destinationBytesPerRow)
                memcpy(rowDestination, source, destinationBytesPerRow)
            }
        }

        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
        )
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: destinationBytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    public func flush() {
        enqueuedCount = 0
        KVMLog.video.info("Sample buffer display layer flush")
        let flush = { [layer, sampleLayer] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sampleLayer.flushAndRemoveImage()
            layer.contents = nil
            CATransaction.commit()
        }
        if Thread.isMainThread {
            flush()
        } else {
            DispatchQueue.main.async(execute: flush)
        }
    }
}

public enum SampleBufferRenderMode: Sendable {
    case sampleBuffer
    case sampleBufferFlushingQueuedFrames
    case directLatestFrame
}

public final class SampleBufferRenderCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private let renderMode: SampleBufferRenderMode
    private weak var display: SampleBufferDisplay?
    private var lastPresentationTime: CMTime?

    public init(flushQueuedFrames: Bool = false) {
        self.renderMode = flushQueuedFrames ? .sampleBufferFlushingQueuedFrames : .sampleBuffer
    }

    public init(renderMode: SampleBufferRenderMode) {
        self.renderMode = renderMode
    }

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

        display?.enqueue(sampleBuffer, renderMode: renderMode)
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
