#if os(macOS)
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import CoreGraphics
import Foundation
import ImageIO
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
        /// Like `keystroke`, but reconnects a fresh RFB session for each
        /// sample so the framebuffer view isn't stale. Cannot measure
        /// latency (each reconnect costs seconds); reports only
        /// hit/miss per keystroke. Use when the target's RFB
        /// implementation freezes the framebuffer for the controlling
        /// connection (e.g. macOS Apple Screen Sharing).
        case keystrokeVerify = "keystroke-verify"
    }

    struct Configuration {
        var mode: Mode
        var samples: Int
        var regionSide: Int
        var changeThreshold: Double
        var settleMs: Int
        var perSampleTimeoutMs: Int
        var echoRegion: CGRect?
        /// Time the key is held down between the keydown and keyup reports.
        /// Sending them back-to-back results in events being coalesced or
        /// dropped by Apple Screen Sharing / the receiving OS, so a real
        /// keystroke needs a measurable hold.
        var keyHoldMs: Int
        /// Verbose per-sample diagnostics: what was sent, what was seen.
        var debugKeys: Bool
    }

    struct InputSample {
        let index: Int
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
        case .keystrokeVerify:
            throw InputLatencyRunnerError.modeHandledElsewhere
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

            let baselineResult = await captureBaseline(
                cursor: cursor,
                centerX: nextPoint.x,
                centerY: nextPoint.y,
                regionSide: configuration.regionSide
            )
            guard let (baseline, _) = baselineResult else {
                samples.append(InputSample(index: sampleIndex, latencyMs: nil, framesSearched: 0))
                continue
            }

            let sentHost = CMClockGetTime(CMClockGetHostTimeClock())
            await sendMouseMove(to: nextPoint, frame: size)

            let (latency, framesSearched, maxDelta, _) = await searchForChange(
                cursor: cursor,
                sentHost: sentHost,
                centerX: nextPoint.x,
                centerY: nextPoint.y,
                regionSide: configuration.regionSide,
                baseline: baseline
            )

            samples.append(InputSample(
                index: sampleIndex,
                latencyMs: latency,
                framesSearched: framesSearched
            ))
            reportProgress(
                sampleIndex: sampleIndex,
                latency: latency,
                framesSearched: framesSearched,
                maxDelta: maxDelta,
                detail: "cursor→(\(nextPoint.x),\(nextPoint.y))"
            )
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

        // Click into the echo region first so the target window/tab has
        // keyboard focus before we start firing keystrokes. Without this,
        // keys land in whatever held focus when the bench connected
        // (typically the URL bar of a freshly-pasted data: URL).
        await clickToFocus(centerX: centerX, centerY: centerY, frame: size)
        try await Task.sleep(nanoseconds: 250_000_000)

        for sampleIndex in 0..<configuration.samples {
            let usage = digitUsages[sampleIndex % digitUsages.count]

            try await Task.sleep(nanoseconds: UInt64(configuration.settleMs) * 1_000_000)

            let baselineResult = await captureBaseline(
                cursor: cursor,
                centerX: centerX,
                centerY: centerY,
                regionSide: regionSide
            )
            guard let (baseline, baselineImageBuffer) = baselineResult else {
                samples.append(InputSample(index: sampleIndex, latencyMs: nil, framesSearched: 0))
                continue
            }

            let sentHost = CMClockGetTime(CMClockGetHostTimeClock())
            await target.sendKeyboardReport(HIDKeyboardReport(modifier: 0, keycodes: [usage]))
            try await Task.sleep(nanoseconds: UInt64(configuration.keyHoldMs) * 1_000_000)
            await target.sendKeyboardReport(HIDKeyboardReport())

            let (latency, framesSearched, maxDelta, lastImageBuffer) = await searchForChange(
                cursor: cursor,
                sentHost: sentHost,
                centerX: centerX,
                centerY: centerY,
                regionSide: regionSide,
                baseline: baseline
            )

            if configuration.debugKeys && sampleIndex == 0 {
                let baselineURL = dumpFramebufferPNG(
                    pixelBuffer: baselineImageBuffer,
                    label: "baseline"
                )
                let finalURL = lastImageBuffer.flatMap { buffer in
                    dumpFramebufferPNG(pixelBuffer: buffer, label: "sample0-post")
                }
                FileHandle.standardError.write(Data(
                    ("    [debug] watch region center=(\(centerX),\(centerY)) side=\(regionSide)\n").utf8
                ))
                if let baselineURL {
                    FileHandle.standardError.write(Data(
                        "    [debug] baseline → \(baselineURL.path)\n".utf8
                    ))
                }
                if let finalURL {
                    FileHandle.standardError.write(Data(
                        "    [debug] sample0-post → \(finalURL.path)\n".utf8
                    ))
                }
            }
            if configuration.debugKeys && sampleIndex == configuration.samples - 1 {
                if let buffer = lastImageBuffer,
                   let endURL = dumpFramebufferPNG(pixelBuffer: buffer, label: "final") {
                    FileHandle.standardError.write(Data(
                        "    [debug] final → \(endURL.path)\n".utf8
                    ))
                }
            }

            samples.append(InputSample(
                index: sampleIndex,
                latencyMs: latency,
                framesSearched: framesSearched
            ))
            let keysym = HIDUsageToX11Keysym.lookup(usage: usage) ?? 0
            reportProgress(
                sampleIndex: sampleIndex,
                latency: latency,
                framesSearched: framesSearched,
                maxDelta: maxDelta,
                detail: String(format: "HID=0x%02X keysym=0x%04X", usage, keysym)
            )
        }
        return samples
    }

    private func dumpFramebufferPNG(pixelBuffer: CVImageBuffer, label: String) -> URL? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let bitmapInfo: UInt32 =
            CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ), let cgImage = context.makeImage() else {
            return nil
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("latencybench-\(timestamp)-\(label).png")
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return url
    }

    private func captureBaseline(
        cursor: PresentationCursor,
        centerX: Int,
        centerY: Int,
        regionSide: Int
    ) async -> (region: PixelRegion, imageBuffer: CVImageBuffer)? {
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
                return (region, imageBuffer)
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
    ) async -> (latency: Double?, framesSearched: Int, maxDelta: Double, lastImageBuffer: CVImageBuffer?) {
        let deadline = Date().addingTimeInterval(
            TimeInterval(configuration.perSampleTimeoutMs) / 1000
        )
        var framesSearched = 0
        var maxDelta: Double = 0
        var lastImageBuffer: CVImageBuffer?
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
            lastImageBuffer = pixelBuffer
            let delta = region.meanAbsoluteDifference(against: baseline)
            if delta > maxDelta { maxDelta = delta }
            if delta >= configuration.changeThreshold {
                let dt = CMTimeSubtract(event.presentedHostTime, sentHost)
                return (CMTimeGetSeconds(dt) * 1000.0, framesSearched, maxDelta, lastImageBuffer)
            }
        }
        return (nil, framesSearched, maxDelta, lastImageBuffer)
    }

    private func reportProgress(
        sampleIndex: Int,
        latency: Double?,
        framesSearched: Int,
        maxDelta: Double,
        detail: String
    ) {
        let isPeriodic = sampleIndex == 0 || (sampleIndex + 1) % 10 == 0
        guard isPeriodic || configuration.debugKeys else { return }
        let latencyText = latency.map { String(format: "%.1fms", $0) } ?? "miss"
        if configuration.debugKeys {
            FileHandle.standardError.write(Data(
                String(
                    format: "  sample %d/%d %@  latency=%@ frames=%d maxDelta=%.2f\n",
                    sampleIndex + 1,
                    configuration.samples,
                    detail as NSString,
                    latencyText as NSString,
                    framesSearched,
                    maxDelta
                ).utf8
            ))
        } else {
            FileHandle.standardError.write(Data(
                String(
                    format: "  sample %d/%d  latency=%@ frames=%d\n",
                    sampleIndex + 1,
                    configuration.samples,
                    latencyText as NSString,
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

    private func clickToFocus(centerX: Int, centerY: Int, frame: CGSize) async {
        guard frame.width > 1, frame.height > 1 else { return }
        let nx = Double(centerX) / max(Double(frame.width) - 1, 1)
        let ny = Double(centerY) / max(Double(frame.height) - 1, 1)
        let x = UInt16(max(1, min(32_767, Int((nx * 32_766).rounded()) + 1)))
        let y = UInt16(max(1, min(32_767, Int((ny * 32_766).rounded()) + 1)))
        // Move first, then primary-button down, then up.
        await target.sendMouseReport(HIDMouseAbsoluteReport(buttons: 0, x: x, y: y, wheel: 0))
        try? await Task.sleep(nanoseconds: 30_000_000)
        await target.sendMouseReport(HIDMouseAbsoluteReport(buttons: 1, x: x, y: y, wheel: 0))
        try? await Task.sleep(nanoseconds: 30_000_000)
        await target.sendMouseReport(HIDMouseAbsoluteReport(buttons: 0, x: x, y: y, wheel: 0))
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
    case modeHandledElsewhere

    var errorDescription: String? {
        switch self {
        case .missingFramebufferSize:
            return "Target did not report a framebuffer size; cannot run input bench."
        case .missingEchoRegion:
            return "Keystroke-echo mode requires --echo-region x,y,w,h."
        case .modeHandledElsewhere:
            return "This input mode is not driven by InputLatencyRunner."
        }
    }
}
#endif
