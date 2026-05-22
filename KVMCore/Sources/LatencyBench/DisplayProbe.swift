#if os(macOS)
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation
import QuartzCore

/// Owns an offscreen `AVSampleBufferDisplayLayer` paired with an
/// `AVSampleBufferRenderSynchronizer`. The synchronizer's timebase is
/// anchored to `CMClockGetHostTimeClock()`, so the PTS values that
/// `RFBFramebuffer.makeSampleBuffer` stamp into sample buffers (host
/// clock) and the H.264 decoder stamps (server clock) are both
/// monotonically advanced.
///
/// For each enqueued sample we record:
/// - `t_enqueue` — host time when the bench handed the sample to the layer.
/// - `t_pts` — the buffer's PTS as the synchronizer sees it.
/// - `t_presented` — the host time when the synchronizer's timebase first
///   crosses the PTS (observed via a periodic time observer).
///
/// Because the synchronizer's timebase is anchored to the host clock, for
/// RFB buffers `t_presented` is essentially `max(t_enqueue, t_pts)`. For
/// H.264 buffers, the PTS lives in the server clock domain so the absolute
/// `t_presented` is not directly comparable across domains — only the
/// **deltas** (`t_present - t_enqueue`, `t_present - t_wire`) are
/// meaningful, and those are computed in host time.
final class DisplayProbe: @unchecked Sendable {
    /// A presentation event carries a `CVImageBuffer` reference. Core Video
    /// image buffers are not formally `Sendable` but are safe to pass between
    /// tasks for read-only access; we mark this `@unchecked Sendable`
    /// accordingly.
    struct PresentationEvent: @unchecked Sendable {
        let sampleIndex: Int
        let wireArrivalHostTime: CMTime?
        let pts: CMTime
        let enqueueHostTime: CMTime
        let presentedHostTime: CMTime
        let imageBuffer: CVImageBuffer?
    }

    private struct Pending {
        let index: Int
        let wire: CMTime?
        let pts: CMTime
        let enqueueHost: CMTime
        let imageBuffer: CVImageBuffer?
    }

    private let synchronizer: AVSampleBufferRenderSynchronizer
    private let displayLayer: AVSampleBufferDisplayLayer
    private let observerQueue = DispatchQueue(label: "io.lyx.latencybench.displayprobe")
    private let stateLock = NSLock()
    private var pending: [Pending] = []
    private var nextSampleIndex = 0
    private var timeBaseOrigin: CMTime?
    private var presentationContinuation: AsyncStream<PresentationEvent>.Continuation?
    let presentationEvents: AsyncStream<PresentationEvent>
    private var timeObserverToken: Any?

    init() {
        self.synchronizer = AVSampleBufferRenderSynchronizer()
        self.displayLayer = AVSampleBufferDisplayLayer()
        self.displayLayer.videoGravity = .resizeAspect

        var presContinuation: AsyncStream<PresentationEvent>.Continuation!
        self.presentationEvents = AsyncStream(bufferingPolicy: .unbounded) { presContinuation = $0 }
        self.presentationContinuation = presContinuation
    }

    /// Starts the synchronizer and begins observing timebase progress.
    /// Must be called from the main thread.
    @MainActor
    func start() {
        synchronizer.addRenderer(displayLayer)

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        synchronizer.setRate(1.0, time: now)

        let interval = CMTime(value: 1, timescale: 120)
        timeObserverToken = synchronizer.addPeriodicTimeObserver(forInterval: interval, queue: observerQueue) {
            [weak self] timebaseTime in
            self?.drainPresented(asOf: timebaseTime)
        }
    }

    @MainActor
    func stop() {
        if let token = timeObserverToken {
            synchronizer.removeTimeObserver(token)
            timeObserverToken = nil
        }
        synchronizer.setRate(0, time: synchronizer.currentTime())
        displayLayer.flush()
        presentationContinuation?.finish()
    }

    /// Enqueues a sample buffer for "display" and registers it for
    /// presentation tracking.
    func enqueue(_ sampleBuffer: CMSampleBuffer, wireArrival: CMTime?) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let enqueueHost = CMClockGetTime(CMClockGetHostTimeClock())
        let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)

        stateLock.lock()
        let index = nextSampleIndex
        nextSampleIndex += 1
        // Anchor the timebase origin so we can map PTS (potentially in a
        // server clock domain) into the host clock domain monotonically.
        if timeBaseOrigin == nil {
            timeBaseOrigin = pts
            stateLock.unlock()
            // Re-anchor the synchronizer to align timebase with this PTS.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.synchronizer.setRate(1.0, time: pts)
            }
            stateLock.lock()
        }
        pending.append(Pending(
            index: index,
            wire: wireArrival,
            pts: pts,
            enqueueHost: enqueueHost,
            imageBuffer: imageBuffer
        ))
        stateLock.unlock()

        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        } else {
            displayLayer.flush()
            displayLayer.enqueue(sampleBuffer)
        }
    }

    private func drainPresented(asOf timebaseTime: CMTime) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var ready: [Pending] = []

        stateLock.lock()
        while let head = pending.first, CMTimeCompare(head.pts, timebaseTime) <= 0 {
            ready.append(head)
            pending.removeFirst()
        }
        stateLock.unlock()

        for item in ready {
            presentationContinuation?.yield(PresentationEvent(
                sampleIndex: item.index,
                wireArrivalHostTime: item.wire,
                pts: item.pts,
                enqueueHostTime: item.enqueueHost,
                presentedHostTime: now,
                imageBuffer: item.imageBuffer
            ))
        }
    }
}
#endif
