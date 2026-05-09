@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import SwiftUI

struct VideoRenderView: NSViewRepresentable {
    let sampleBuffer: CMSampleBuffer?
    let flushToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SampleBufferDisplayView {
        SampleBufferDisplayView()
    }

    func updateNSView(_ nsView: SampleBufferDisplayView, context: Context) {
        if context.coordinator.lastFlushToken != flushToken {
            context.coordinator.lastFlushToken = flushToken
            context.coordinator.lastPresentationTime = nil
            nsView.flush()
        }

        guard let sampleBuffer else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard context.coordinator.lastPresentationTime != presentationTime else { return }
        context.coordinator.lastPresentationTime = presentationTime
        nsView.enqueue(sampleBuffer)
    }

    final class Coordinator {
        var lastFlushToken: Int = 0
        var lastPresentationTime: CMTime?
    }
}

final class SampleBufferDisplayView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer = displayLayer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }

    func flush() {
        displayLayer.flushAndRemoveImage()
    }
}
