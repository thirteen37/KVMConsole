#if os(macOS)
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import CoreGraphics
import Foundation
import KVMCore

/// Reconnect-per-sample variant of keystroke-echo input verification.
///
/// Some RFB servers (notably macOS Apple Screen Sharing) freeze the
/// framebuffer view for the controlling connection — keystrokes do reach
/// the focused app but our connection never sees the resulting pixel
/// change. To work around that we open a fresh RFB session per sample so
/// each observation starts from a fresh framebuffer snapshot. The cost is
/// several seconds per sample for handshake + initial frame, so latency
/// timings are not produced; the runner reports only hit/miss.
@MainActor
final class KeystrokeVerifier {
    struct Configuration {
        var samples: Int
        var regionSide: Int
        var changeThreshold: Double
        var settleMs: Int
        var perSampleTimeoutMs: Int
        var echoRegion: CGRect
        var keyHoldMs: Int
        var postKeyHoldMs: Int
        var debugKeys: Bool
    }

    let device: Device
    let password: String
    let configuration: Configuration

    init(device: Device, password: String, configuration: Configuration) {
        self.device = device
        self.password = password
        self.configuration = configuration
    }

    func run() async throws -> [InputLatencyRunner.InputSample] {
        let digitUsages: [UInt8] = [0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27]
        let centerX = Int(configuration.echoRegion.midX)
        let centerY = Int(configuration.echoRegion.midY)
        let regionSide = max(
            configuration.regionSide,
            Int(min(configuration.echoRegion.width, configuration.echoRegion.height))
        )

        FileHandle.standardError.write(Data(
            "Measuring input verification (mode=keystroke-verify, n=\(configuration.samples)). Each sample reconnects twice; this takes a while.\n".utf8
        ))

        var samples: [InputLatencyRunner.InputSample] = []
        var clickIssued = false

        for sampleIndex in 0..<configuration.samples {
            let usage = digitUsages[sampleIndex % digitUsages.count]
            let keysym = HIDUsageToX11Keysym.lookup(usage: usage) ?? 0

            // Connection 1: capture baseline + send keystroke.
            let sender = RFBLatencyTarget(device: device, password: password)
            do {
                try await sender.connect()
            } catch {
                samples.append(InputLatencyRunner.InputSample(
                    index: sampleIndex, latencyMs: nil, framesSearched: 0
                ))
                continue
            }
            guard let baseline = await captureRegion(
                target: sender,
                centerX: centerX,
                centerY: centerY,
                regionSide: regionSide
            ) else {
                await sender.disconnect()
                samples.append(InputLatencyRunner.InputSample(
                    index: sampleIndex, latencyMs: nil, framesSearched: 0
                ))
                continue
            }
            if !clickIssued, let size = await sender.framebufferSize {
                await clickToFocus(target: sender, centerX: centerX, centerY: centerY, frame: size)
                try await Task.sleep(nanoseconds: 250_000_000)
                clickIssued = true
            }
            await sender.sendKeyboardReport(HIDKeyboardReport(modifier: 0, keycodes: [usage]))
            try await Task.sleep(nanoseconds: UInt64(configuration.keyHoldMs) * 1_000_000)
            await sender.sendKeyboardReport(HIDKeyboardReport())
            try await Task.sleep(nanoseconds: UInt64(configuration.postKeyHoldMs) * 1_000_000)
            await sender.disconnect()

            // Connection 2: observe the post-keystroke framebuffer.
            let observer = RFBLatencyTarget(device: device, password: password)
            do {
                try await observer.connect()
            } catch {
                samples.append(InputLatencyRunner.InputSample(
                    index: sampleIndex, latencyMs: nil, framesSearched: 0
                ))
                continue
            }
            let post = await captureRegion(
                target: observer,
                centerX: centerX,
                centerY: centerY,
                regionSide: regionSide
            )
            await observer.disconnect()

            guard let post else {
                samples.append(InputLatencyRunner.InputSample(
                    index: sampleIndex, latencyMs: nil, framesSearched: 0
                ))
                continue
            }
            let delta = post.meanAbsoluteDifference(against: baseline)
            let hit = delta >= configuration.changeThreshold
            samples.append(InputLatencyRunner.InputSample(
                index: sampleIndex,
                latencyMs: hit ? 0 : nil,
                framesSearched: 1
            ))

            if configuration.debugKeys || sampleIndex == 0 || (sampleIndex + 1) % 5 == 0 {
                FileHandle.standardError.write(Data(
                    String(
                        format: "  sample %d/%d  HID=0x%02X keysym=0x%04X  %@  delta=%.2f\n",
                        sampleIndex + 1,
                        configuration.samples,
                        usage,
                        keysym,
                        hit ? ("HIT" as NSString) : ("miss" as NSString),
                        delta
                    ).utf8
                ))
            }
        }
        return samples
    }

    private func captureRegion(
        target: RFBLatencyTarget,
        centerX: Int,
        centerY: Int,
        regionSide: Int
    ) async -> PixelRegion? {
        let cursor = SampleBufferCursor(stream: target.sampleBuffers)
        let deadline = Date().addingTimeInterval(
            TimeInterval(configuration.perSampleTimeoutMs) / 1000
        )
        while Date() < deadline {
            guard let sample = await cursor.next() else { return nil }
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
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

    private func clickToFocus(
        target: RFBLatencyTarget,
        centerX: Int,
        centerY: Int,
        frame: CGSize
    ) async {
        guard frame.width > 1, frame.height > 1 else { return }
        let nx = Double(centerX) / max(Double(frame.width) - 1, 1)
        let ny = Double(centerY) / max(Double(frame.height) - 1, 1)
        let x = UInt16(max(1, min(32_767, Int((nx * 32_766).rounded()) + 1)))
        let y = UInt16(max(1, min(32_767, Int((ny * 32_766).rounded()) + 1)))
        await target.sendMouseReport(HIDMouseAbsoluteReport(buttons: 0, x: x, y: y, wheel: 0))
        try? await Task.sleep(nanoseconds: 30_000_000)
        await target.sendMouseReport(HIDMouseAbsoluteReport(buttons: 1, x: x, y: y, wheel: 0))
        try? await Task.sleep(nanoseconds: 30_000_000)
        await target.sendMouseReport(HIDMouseAbsoluteReport(buttons: 0, x: x, y: y, wheel: 0))
    }
}

/// Reference-typed wrapper around an `AsyncStream<CMSampleBuffer>` iterator.
/// Avoids Swift 6 strict-concurrency `sending` warnings when an iterator is
/// awaited inside a `@MainActor` helper.
final class SampleBufferCursor: @unchecked Sendable {
    private var iterator: AsyncStream<CMSampleBuffer>.Iterator

    init(stream: AsyncStream<CMSampleBuffer>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func next() async -> CMSampleBuffer? {
        await iterator.next()
    }
}
#endif
