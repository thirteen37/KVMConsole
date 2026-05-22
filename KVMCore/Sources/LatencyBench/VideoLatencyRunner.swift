#if os(macOS)
@preconcurrency import CoreMedia
import Foundation
import KVMCore

/// Drives a `LatencyTarget` and feeds its sample buffers through a
/// `DisplayProbe`, recording per-frame latency samples for the report.
final class VideoLatencyRunner {
    struct Configuration {
        var duration: TimeInterval
        var maxFrames: Int?
    }

    struct FrameSample {
        let frameIndex: Int
        let wireToEnqueueMs: Double?
        let enqueueToPresentedMs: Double
        let wireToPresentedMs: Double?
        let interFrameMs: Double?
    }

    let target: LatencyTarget
    let configuration: Configuration

    init(target: LatencyTarget, configuration: Configuration) {
        self.target = target
        self.configuration = configuration
    }

    @MainActor
    func run() async throws -> [FrameSample] {
        let probe = DisplayProbe()
        probe.start()

        let sampleBuffers = target.sampleBuffers
        let forwarder = Task { @Sendable in
            for await sample in sampleBuffers {
                let wire = SampleBufferLatencyTag.wireArrivalHostTime(of: sample)
                probe.enqueue(sample, wireArrival: wire)
            }
        }

        let frameLimit = configuration.maxFrames
        let duration = configuration.duration

        // Watchdog: when the duration elapses, stop the probe so the
        // `for await` below returns. Without this the loop blocks forever
        // when the framebuffer stops sending updates (idle screen on Apple
        // Screen Sharing).
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            probe.stop()
        }

        let limitDescription = frameLimit.map { String($0) } ?? "no limit"
        FileHandle.standardError.write(Data(
            "Capturing video latency for up to \(Int(duration))s (frames: \(limitDescription))…\n".utf8
        ))

        var samples: [FrameSample] = []
        var lastPresented: CMTime?

        for await event in probe.presentationEvents {
            let wireMs = event.wireArrivalHostTime.flatMap { wire -> Double? in
                let dt = CMTimeSubtract(event.enqueueHostTime, wire)
                return CMTimeGetSeconds(dt) * 1000.0
            }
            let enqueueToPresentedMs = CMTimeGetSeconds(
                CMTimeSubtract(event.presentedHostTime, event.enqueueHostTime)
            ) * 1000.0
            let wireToPresentedMs = event.wireArrivalHostTime.flatMap { wire -> Double? in
                let dt = CMTimeSubtract(event.presentedHostTime, wire)
                return CMTimeGetSeconds(dt) * 1000.0
            }
            let interFrameMs: Double? = lastPresented.flatMap { prev in
                let dt = CMTimeSubtract(event.presentedHostTime, prev)
                return CMTimeGetSeconds(dt) * 1000.0
            }
            lastPresented = event.presentedHostTime

            samples.append(FrameSample(
                frameIndex: samples.count,
                wireToEnqueueMs: wireMs,
                enqueueToPresentedMs: enqueueToPresentedMs,
                wireToPresentedMs: wireToPresentedMs,
                interFrameMs: interFrameMs
            ))

            if samples.count == 1 || samples.count % 30 == 0 {
                let interFrameText = interFrameMs.map { String(format: "%.1fms", $0) } ?? "—"
                let wireToPresentedText = wireToPresentedMs.map { String(format: "%.1fms", $0) } ?? "—"
                FileHandle.standardError.write(Data(
                    String(
                        format: "  frame %d  wire→present=%@  enqueue→present=%.1fms  Δ=%@\n",
                        samples.count,
                        wireToPresentedText as NSString,
                        enqueueToPresentedMs,
                        interFrameText as NSString
                    ).utf8
                ))
            }

            if let frameLimit, samples.count >= frameLimit { break }
        }

        watchdog.cancel()
        forwarder.cancel()
        probe.stop()
        return samples
    }
}
#endif
