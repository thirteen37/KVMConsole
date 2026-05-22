#if os(macOS)
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import CoreGraphics
import Foundation
import KVMCore

/// Drives input events and measures the on-screen round-trip latency by
/// watching a region of decoded frames for a visible change. Cursor-echo
/// mode cycles the pointer across a grid; keystroke-echo mode (PR3) sends
/// digit keys and watches a user-specified echo region.
@MainActor
final class InputLatencyRunner {
    enum Mode: String, Sendable {
        case cursor
        case keystroke
    }

    struct Configuration {
        var mode: Mode
        var samples: Int
        var regionSide: Int
        var changeThreshold: Double
        var settleMs: Int
        var perSampleTimeoutMs: Int
        var echoRegion: CGRect?
    }

    struct InputSample {
        let index: Int
        let sentMs: Double
        let latencyMs: Double?
        let framesSearched: Int
    }

    let target: LatencyTarget
    let configuration: Configuration

    init(target: LatencyTarget, configuration: Configuration) {
        self.target = target
        self.configuration = configuration
    }

    func run() async throws -> [InputSample] {
        let probe = DisplayProbe()
        probe.start()

        let sampleBuffers = target.sampleBuffers
        let forwarder = Task { @Sendable in
            for await sample in sampleBuffers {
                let wire = SampleBufferLatencyTag.wireArrivalHostTime(of: sample)
                probe.enqueue(sample, wireArrival: wire)
            }
        }

        let cursor = PresentationCursor(stream: probe.presentationEvents)
        for _ in 0..<3 { _ = await cursor.next() }

        guard let size = await target.framebufferSize else {
            forwarder.cancel()
            probe.stop()
            throw InputLatencyRunnerError.missingFramebufferSize
        }

        FileHandle.standardError.write(Data(
            "Measuring input latency (mode=\(configuration.mode.rawValue), n=\(configuration.samples))…\n".utf8
        ))

        let result: [InputSample]
        switch configuration.mode {
        case .cursor:
            result = try await runCursorMode(cursor: cursor, size: size)
        case .keystroke:
            guard let echoRegion = configuration.echoRegion else {
                forwarder.cancel()
                probe.stop()
                throw InputLatencyRunnerError.missingEchoRegion
            }
            result = try await runKeystrokeMode(
                cursor: cursor,
                size: size,
                echoRegion: echoRegion
            )
        }

        forwarder.cancel()
        probe.stop()
        return result
    }

    private func runCursorMode(cursor: PresentationCursor, size: CGSize) async throws -> [InputSample] {
        var samples: [InputSample] = []
        let grid = gridPoints(width: Int(size.width), height: Int(size.height))

        for sampleIndex in 0..<configuration.samples {
            let nextPoint = grid[sampleIndex % grid.count]
            let restPoint = grid[(sampleIndex + grid.count / 2) % grid.count]

            await sendMouseMove(to: restPoint, frame: size)
            try await Task.sleep(nanoseconds: UInt64(configuration.settleMs) * 1_000_000)

            let baseline = await captureBaseline(
                cursor: cursor,
                centerX: nextPoint.x,
                centerY: nextPoint.y,
                regionSide: configuration.regionSide
            )
            guard let baseline else {
                samples.append(InputSample(index: sampleIndex, sentMs: 0, latencyMs: nil, framesSearched: 0))
                continue
            }

            let sentHost = CMClockGetTime(CMClockGetHostTimeClock())
            await sendMouseMove(to: nextPoint, frame: size)

            let (latency, framesSearched) = await searchForChange(
                cursor: cursor,
                sentHost: sentHost,
                centerX: nextPoint.x,
                centerY: nextPoint.y,
                regionSide: configuration.regionSide,
                baseline: baseline
            )

            samples.append(InputSample(
                index: sampleIndex,
                sentMs: 0,
                latencyMs: latency,
                framesSearched: framesSearched
            ))
            reportProgress(sampleIndex: sampleIndex, latency: latency, framesSearched: framesSearched)
        }
        return samples
    }

    private func runKeystrokeMode(
        cursor: PresentationCursor,
        size: CGSize,
        echoRegion: CGRect
    ) async throws -> [InputSample] {
        var samples: [InputSample] = []
        let digitUsages: [UInt8] = [0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27]
        let centerX = Int(echoRegion.midX)
        let centerY = Int(echoRegion.midY)
        let regionSide = max(configuration.regionSide, Int(min(echoRegion.width, echoRegion.height)))

        for sampleIndex in 0..<configuration.samples {
            let usage = digitUsages[sampleIndex % digitUsages.count]

            try await Task.sleep(nanoseconds: UInt64(configuration.settleMs) * 1_000_000)

            let baseline = await captureBaseline(
                cursor: cursor,
                centerX: centerX,
                centerY: centerY,
                regionSide: regionSide
            )
            guard let baseline else {
                samples.append(InputSample(index: sampleIndex, sentMs: 0, latencyMs: nil, framesSearched: 0))
                continue
            }

            let sentHost = CMClockGetTime(CMClockGetHostTimeClock())
            await target.sendKeyboardReport(HIDKeyboardReport(modifier: 0, keycodes: [usage]))
            await target.sendKeyboardReport(HIDKeyboardReport())

            let (latency, framesSearched) = await searchForChange(
                cursor: cursor,
                sentHost: sentHost,
                centerX: centerX,
                centerY: centerY,
                regionSide: regionSide,
                baseline: baseline
            )

            samples.append(InputSample(
                index: sampleIndex,
                sentMs: 0,
                latencyMs: latency,
                framesSearched: framesSearched
            ))
            reportProgress(sampleIndex: sampleIndex, latency: latency, framesSearched: framesSearched)
        }
        return samples
    }

    private func captureBaseline(
        cursor: PresentationCursor,
        centerX: Int,
        centerY: Int,
        regionSide: Int
    ) async -> PixelRegion? {
        let deadline = Date().addingTimeInterval(
            TimeInterval(configuration.perSampleTimeoutMs) / 1000
        )
        while Date() < deadline {
            guard let event = await cursor.next() else { return nil }
            guard let imageBuffer = event.imageBuffer else { continue }
            if let region = PixelRegionExtractor.extract(
                from: imageBuffer,
                centerX: centerX,
                centerY: centerY,
                regionSide: regionSide
            ) {
                return region
            }
        }
        return nil
    }

    private func searchForChange(
        cursor: PresentationCursor,
        sentHost: CMTime,
        centerX: Int,
        centerY: Int,
        regionSide: Int,
        baseline: PixelRegion
    ) async -> (latency: Double?, framesSearched: Int) {
        let deadline = Date().addingTimeInterval(
            TimeInterval(configuration.perSampleTimeoutMs) / 1000
        )
        var framesSearched = 0
        while Date() < deadline {
            guard let event = await cursor.next() else { break }
            framesSearched += 1
            if CMTimeCompare(event.presentedHostTime, sentHost) <= 0 { continue }
            guard
                let pixelBuffer = event.imageBuffer,
                let region = PixelRegionExtractor.extract(
                    from: pixelBuffer,
                    centerX: centerX,
                    centerY: centerY,
                    regionSide: regionSide
                )
            else { continue }
            let delta = region.meanAbsoluteDifference(against: baseline)
            if delta >= configuration.changeThreshold {
                let dt = CMTimeSubtract(event.presentedHostTime, sentHost)
                return (CMTimeGetSeconds(dt) * 1000.0, framesSearched)
            }
        }
        return (nil, framesSearched)
    }

    private func reportProgress(sampleIndex: Int, latency: Double?, framesSearched: Int) {
        if sampleIndex == 0 || (sampleIndex + 1) % 10 == 0 {
            FileHandle.standardError.write(Data(
                String(
                    format: "  sample %d/%d  latency=%@ frames=%d\n",
                    sampleIndex + 1,
                    configuration.samples,
                    latency.map { String(format: "%.1fms", $0) } ?? "miss",
                    framesSearched
                ).utf8
            ))
        }
    }

    private func gridPoints(width: Int, height: Int) -> [(x: Int, y: Int)] {
        let margin = configuration.regionSide
        let inner = (
            xLo: margin,
            xHi: width - margin,
            yLo: margin,
            yHi: height - margin
        )
        return [
            (inner.xLo, inner.yLo),
            (inner.xHi, inner.yLo),
            (inner.xLo, inner.yHi),
            (inner.xHi, inner.yHi),
            ((inner.xLo + inner.xHi) / 2, inner.yLo),
            ((inner.xLo + inner.xHi) / 2, inner.yHi),
            (inner.xLo, (inner.yLo + inner.yHi) / 2),
            (inner.xHi, (inner.yLo + inner.yHi) / 2)
        ]
    }

    private func sendMouseMove(to point: (x: Int, y: Int), frame: CGSize) async {
        guard frame.width > 1, frame.height > 1 else { return }
        let nx = Double(point.x) / max(Double(frame.width) - 1, 1)
        let ny = Double(point.y) / max(Double(frame.height) - 1, 1)
        let x = UInt16(max(1, min(32_767, Int((nx * 32_766).rounded()) + 1)))
        let y = UInt16(max(1, min(32_767, Int((ny * 32_766).rounded()) + 1)))
        let report = HIDMouseAbsoluteReport(buttons: 0, x: x, y: y, wheel: 0)
        await target.sendMouseReport(report)
    }
}

/// Reference-typed wrapper around an `AsyncStream<DisplayProbe.PresentationEvent>`
/// iterator. Using a class lets us share the iterator between helper methods
/// without `inout` parameters, which trip Swift 6 strict-concurrency
/// checks around `next()` being a `nonisolated` async method.
final class PresentationCursor: @unchecked Sendable {
    private var iterator: AsyncStream<DisplayProbe.PresentationEvent>.Iterator

    init(stream: AsyncStream<DisplayProbe.PresentationEvent>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func next() async -> DisplayProbe.PresentationEvent? {
        await iterator.next()
    }
}

enum InputLatencyRunnerError: Error, LocalizedError {
    case missingFramebufferSize
    case missingEchoRegion

    var errorDescription: String? {
        switch self {
        case .missingFramebufferSize:
            return "Target did not report a framebuffer size; cannot run input bench."
        case .missingEchoRegion:
            return "Keystroke-echo mode requires --echo-region x,y,w,h."
        }
    }
}
#endif
