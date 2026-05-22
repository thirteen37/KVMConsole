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

        let frameLimit = configuration.maxFrames ?? Int.max
        let duration = configuration.duration

        FileHandle.standardError.write(Data(
            "Capturing video latency for up to \(Int(duration))s (or \(frameLimit) frames)…\n".utf8
        ))

        var samples: [FrameSample] = []
        var lastPresented: CMTime?
        let start = Date()

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
                FileHandle.standardError.write(Data(
                    String(
                        format: "  frame %d  wire→present=%.1fms  enqueue→present=%.1fms  Δ=%.1fms\n",
                        samples.count,
                        wireToPresentedMs ?? .nan,
                        enqueueToPresentedMs,
                        interFrameMs ?? .nan
                    ).utf8
                ))
            }

            if samples.count >= frameLimit { break }
            if Date().timeIntervalSince(start) >= duration { break }
        }

        forwarder.cancel()
        probe.stop()
        return samples
    }
}
#endif
