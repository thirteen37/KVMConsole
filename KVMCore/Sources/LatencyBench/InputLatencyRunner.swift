#if os(macOS)
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation
import KVMCore

/// Sends low-impact pointer moves and measures how long it takes for the
/// remote framebuffer echo to become visible through the local render path.
final class InputLatencyRunner {
    enum InputMode: String, Sendable {
        case cursor
        case keyboard
    }

    struct Configuration {
        var mode: InputMode
        var sampleCount: Int
        var warmupCount: Int
        var interval: TimeInterval
        var timeout: TimeInterval
        var regionSide: Int
        var changeThreshold: Int
        var pixelDeltaThreshold: Int
    }

    struct InputSample {
        let sampleIndex: Int
        let inputMode: String
        let fromX: UInt16
        let fromY: UInt16
        let toX: UInt16
        let toY: UInt16
        let hit: Bool
        let changedPixels: Int
        let framesObserved: Int
        let inputToWireArrivalMs: Double?
        let wireToPresentedMs: Double?
        let inputToPresentedMs: Double?
    }

    private let target: LatencyTarget
    private let configuration: Configuration

    init(target: LatencyTarget, configuration: Configuration) {
        self.target = target
        self.configuration = configuration
    }

    @MainActor
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

        let mailbox = AsyncMailbox<DisplayProbe.PresentationEvent>()
        let presenter = Task { @Sendable in
            for await event in probe.presentationEvents {
                mailbox.yield(event)
            }
            mailbox.finish()
        }

        defer {
            forwarder.cancel()
            presenter.cancel()
            probe.stop()
        }

        let unit = configuration.mode == .cursor ? "cursor moves" : "keystrokes"
        FileHandle.standardError.write(Data(
            "Capturing input latency with \(configuration.sampleCount) \(unit) (timeout: \(String(format: "%.1f", configuration.timeout))s)…\n".utf8
        ))
        if configuration.warmupCount > 0 {
            FileHandle.standardError.write(Data(
                "  warming up with \(configuration.warmupCount) unreported \(unit)…\n".utf8
            ))
        }

        guard var lastEvent = await mailbox.next(timeout: 10) else {
            throw InputLatencyRunnerError.noPresentedFrames
        }

        let points = Self.cursorPoints()
        var currentPoint = points[0]
        if configuration.mode == .cursor {
            await target.sendMouseReport(.init(x: currentPoint.x, y: currentPoint.y))
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        while let event = mailbox.poll() {
            lastEvent = event
        }

        var samples: [InputSample] = []
        let totalInputs = configuration.warmupCount + configuration.sampleCount
        for probeIndex in 0..<totalInputs {
            while let event = mailbox.poll() {
                lastEvent = event
            }

            let nextPoint = points[(probeIndex + 1) % points.count]
            guard let imageBuffer = lastEvent.imageBuffer else {
                throw InputLatencyRunnerError.missingImageBuffer
            }
            let regions: [PixelRegion]
            switch configuration.mode {
            case .cursor:
                regions = Self.cursorRegions(
                    from: currentPoint,
                    to: nextPoint,
                    imageBuffer: imageBuffer,
                    side: configuration.regionSide
                )
            case .keyboard:
                regions = [Self.fullFrameRegion(imageBuffer: imageBuffer)]
            }
            let baseline = try PixelRegionSnapshot(imageBuffer: imageBuffer, regions: regions)

            let inputHostTime = CMClockGetTime(CMClockGetHostTimeClock())
            switch configuration.mode {
            case .cursor:
                await target.sendMouseReport(.init(x: nextPoint.x, y: nextPoint.y))
            case .keyboard:
                await Self.sendKeyboardProbe(index: probeIndex, target: target)
            }

            let deadline = Date().addingTimeInterval(configuration.timeout)
            var framesObserved = 0
            var changedPixels = 0
            var hitEvent: DisplayProbe.PresentationEvent?

            while Date() < deadline {
                let remaining = max(0.01, deadline.timeIntervalSinceNow)
                guard let event = await mailbox.next(timeout: remaining) else { break }
                framesObserved += 1
                lastEvent = event
                if let wireArrival = event.wireArrivalHostTime,
                   CMTimeCompare(wireArrival, inputHostTime) < 0 {
                    continue
                }
                guard let candidate = event.imageBuffer else { continue }
                changedPixels = max(
                    changedPixels,
                    try baseline.changedPixels(
                        comparedTo: candidate,
                        pixelDeltaThreshold: configuration.pixelDeltaThreshold,
                        limit: configuration.changeThreshold
                    )
                )
                if changedPixels >= configuration.changeThreshold {
                    hitEvent = event
                    break
                }
            }

            let inputToWireArrivalMs = hitEvent?.wireArrivalHostTime.map {
                CMTimeGetSeconds(CMTimeSubtract($0, inputHostTime)) * 1000.0
            }
            let wireToPresentedMs = hitEvent?.wireArrivalHostTime.map {
                CMTimeGetSeconds(CMTimeSubtract(hitEvent!.presentedHostTime, $0)) * 1000.0
            }
            let inputToPresentedMs = hitEvent.map {
                CMTimeGetSeconds(CMTimeSubtract($0.presentedHostTime, inputHostTime)) * 1000.0
            }

            if probeIndex >= configuration.warmupCount {
                let sampleIndex = probeIndex - configuration.warmupCount
                let sample = InputSample(
                    sampleIndex: sampleIndex,
                    inputMode: configuration.mode.rawValue,
                    fromX: configuration.mode == .cursor ? currentPoint.x : 0,
                    fromY: configuration.mode == .cursor ? currentPoint.y : 0,
                    toX: configuration.mode == .cursor ? nextPoint.x : 0,
                    toY: configuration.mode == .cursor ? nextPoint.y : 0,
                    hit: hitEvent != nil,
                    changedPixels: changedPixels,
                    framesObserved: framesObserved,
                    inputToWireArrivalMs: inputToWireArrivalMs,
                    wireToPresentedMs: wireToPresentedMs,
                    inputToPresentedMs: inputToPresentedMs
                )
                samples.append(sample)

                if sampleIndex == 0 || (sampleIndex + 1) % 10 == 0 || hitEvent == nil {
                    let latencyText = inputToPresentedMs.map { String(format: "%.1fms", $0) } ?? "miss"
                    FileHandle.standardError.write(Data(
                        "  input \(sampleIndex + 1)  visible=\(latencyText)  changedPixels=\(changedPixels)  frames=\(framesObserved)\n".utf8
                    ))
                }
            } else if hitEvent == nil {
                FileHandle.standardError.write(Data(
                    "  warmup \(probeIndex + 1)  visible=miss  changedPixels=\(changedPixels)  frames=\(framesObserved)\n".utf8
                ))
            }

            currentPoint = nextPoint
            if configuration.interval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(configuration.interval * 1_000_000_000))
            }
        }

        return samples
    }

    private static func cursorPoints() -> [(x: UInt16, y: UInt16)] {
        [
            (UInt16(32_768 * 1 / 4), UInt16(32_768 / 2)),
            (UInt16(32_768 * 3 / 4), UInt16(32_768 / 2)),
            (UInt16(32_768 / 2), UInt16(32_768 * 1 / 4)),
            (UInt16(32_768 / 2), UInt16(32_768 * 3 / 4)),
        ]
    }

    private static func cursorRegions(
        from: (x: UInt16, y: UInt16),
        to: (x: UInt16, y: UInt16),
        imageBuffer: CVImageBuffer,
        side: Int
    ) -> [PixelRegion] {
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        return [
            PixelRegion.centered(at: pixelPoint(from, width: width, height: height), side: side, boundsWidth: width, boundsHeight: height),
            PixelRegion.centered(at: pixelPoint(to, width: width, height: height), side: side, boundsWidth: width, boundsHeight: height),
        ].filter { $0.width > 0 && $0.height > 0 }
    }

    private static func fullFrameRegion(imageBuffer: CVImageBuffer) -> PixelRegion {
        PixelRegion(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer)
        )
    }

    @MainActor
    private static func sendKeyboardProbe(index: Int, target: LatencyTarget) async {
        let keys: [UInt8] = [
            0x04, // a
            0x16, // s
            0x07, // d
            0x09, // f
            0x0D, // j
            0x0E, // k
            0x0F, // l
        ]
        let key = keys[index % keys.count]
        await target.sendKeyboardReport(HIDKeyboardReport(keycodes: [key]))
        try? await Task.sleep(nanoseconds: 25_000_000)
        await target.sendKeyboardReport(HIDKeyboardReport())
    }

    private static func pixelPoint(
        _ point: (x: UInt16, y: UInt16),
        width: Int,
        height: Int
    ) -> (x: Int, y: Int) {
        let x = Int((Double(max(1, point.x) - 1) / 32_767.0 * Double(max(0, width - 1))).rounded())
        let y = Int((Double(max(1, point.y) - 1) / 32_767.0 * Double(max(0, height - 1))).rounded())
        return (x, y)
    }
}

enum InputLatencyRunnerError: Error, LocalizedError {
    case noPresentedFrames
    case missingImageBuffer
    case unsupportedPixelFormat(OSType)

    var errorDescription: String? {
        switch self {
        case .noPresentedFrames:
            return "No presented frames were observed before starting input measurements."
        case .missingImageBuffer:
            return "Presented frame did not include an image buffer."
        case .unsupportedPixelFormat(let format):
            return "Unsupported pixel format for input diffing: \(format)."
        }
    }
}

private struct PixelRegion: Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    static func centered(
        at point: (x: Int, y: Int),
        side: Int,
        boundsWidth: Int,
        boundsHeight: Int
    ) -> PixelRegion {
        let side = max(1, side)
        let half = side / 2
        let minX = max(0, point.x - half)
        let minY = max(0, point.y - half)
        let maxX = min(boundsWidth, minX + side)
        let maxY = min(boundsHeight, minY + side)
        return PixelRegion(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}

private struct PixelRegionSnapshot {
    private struct Segment {
        let region: PixelRegion
        let data: Data
    }

    private let pixelFormat: OSType
    private let segments: [Segment]

    init(imageBuffer: CVImageBuffer, regions: [PixelRegion]) throws {
        pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        segments = try Self.captureSegments(imageBuffer: imageBuffer, regions: regions, pixelFormat: pixelFormat)
    }

    func changedPixels(
        comparedTo imageBuffer: CVImageBuffer,
        pixelDeltaThreshold: Int,
        limit: Int
    ) throws -> Int {
        guard CVPixelBufferGetPixelFormatType(imageBuffer) == pixelFormat else {
            return 0
        }
        guard containsAllRegions(in: imageBuffer) else { return 0 }

        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(imageBuffer) else { return 0 }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
            return compareBGRA(
                base: base.assumingMemoryBound(to: UInt8.self),
                bytesPerRow: bytesPerRow,
                pixelDeltaThreshold: pixelDeltaThreshold,
                limit: limit
            )
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard let base = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0) else { return 0 }
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0)
            return compareLuma(
                base: base.assumingMemoryBound(to: UInt8.self),
                bytesPerRow: bytesPerRow,
                pixelDeltaThreshold: pixelDeltaThreshold,
                limit: limit
            )
        default:
            throw InputLatencyRunnerError.unsupportedPixelFormat(pixelFormat)
        }
    }

    private func containsAllRegions(in imageBuffer: CVImageBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        return segments.allSatisfy { segment in
            segment.region.x >= 0
                && segment.region.y >= 0
                && segment.region.x + segment.region.width <= width
                && segment.region.y + segment.region.height <= height
        }
    }

    private static func captureSegments(
        imageBuffer: CVImageBuffer,
        regions: [PixelRegion],
        pixelFormat: OSType
    ) throws -> [Segment] {
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(imageBuffer) else { return [] }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
            return regions.map { region in
                Segment(
                    region: region,
                    data: copyRows(
                        base: base.assumingMemoryBound(to: UInt8.self),
                        bytesPerRow: bytesPerRow,
                        region: region,
                        bytesPerPixel: 4
                    )
                )
            }
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard let base = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0) else { return [] }
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0)
            return regions.map { region in
                Segment(
                    region: region,
                    data: copyRows(
                        base: base.assumingMemoryBound(to: UInt8.self),
                        bytesPerRow: bytesPerRow,
                        region: region,
                        bytesPerPixel: 1
                    )
                )
            }
        default:
            throw InputLatencyRunnerError.unsupportedPixelFormat(pixelFormat)
        }
    }

    private static func copyRows(
        base: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        region: PixelRegion,
        bytesPerPixel: Int
    ) -> Data {
        var data = Data(capacity: region.width * region.height * bytesPerPixel)
        for row in 0..<region.height {
            let start = base.advanced(by: (region.y + row) * bytesPerRow + region.x * bytesPerPixel)
            data.append(start, count: region.width * bytesPerPixel)
        }
        return data
    }

    private func compareBGRA(
        base: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        pixelDeltaThreshold: Int,
        limit: Int
    ) -> Int {
        var changed = 0
        for segment in segments {
            changed += segment.data.withUnsafeBytes { rawBuffer in
                guard let snapshotBase = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                var segmentChanged = 0
                for row in 0..<segment.region.height {
                    let candidate = base.advanced(by: (segment.region.y + row) * bytesPerRow + segment.region.x * 4)
                    let snapshot = snapshotBase.advanced(by: row * segment.region.width * 4)
                    for column in 0..<segment.region.width {
                        let offset = column * 4
                        let delta =
                            abs(Int(candidate[offset]) - Int(snapshot[offset])) +
                            abs(Int(candidate[offset + 1]) - Int(snapshot[offset + 1])) +
                            abs(Int(candidate[offset + 2]) - Int(snapshot[offset + 2]))
                        if delta >= pixelDeltaThreshold {
                            segmentChanged += 1
                            if changed + segmentChanged >= limit { return segmentChanged }
                        }
                    }
                }
                return segmentChanged
            }
            if changed >= limit { return changed }
        }
        return changed
    }

    private func compareLuma(
        base: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        pixelDeltaThreshold: Int,
        limit: Int
    ) -> Int {
        var changed = 0
        for segment in segments {
            changed += segment.data.withUnsafeBytes { rawBuffer in
                guard let snapshotBase = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                var segmentChanged = 0
                for row in 0..<segment.region.height {
                    let candidate = base.advanced(by: (segment.region.y + row) * bytesPerRow + segment.region.x)
                    let snapshot = snapshotBase.advanced(by: row * segment.region.width)
                    for column in 0..<segment.region.width where abs(Int(candidate[column]) - Int(snapshot[column])) >= pixelDeltaThreshold {
                        segmentChanged += 1
                        if changed + segmentChanged >= limit { return segmentChanged }
                    }
                }
                return segmentChanged
            }
            if changed >= limit { return changed }
        }
        return changed
    }
}

private final class AsyncMailbox<Element: Sendable>: @unchecked Sendable {
    private final class Waiter {
        let id = UUID()
        let continuation: CheckedContinuation<Element?, Never>
        var timeoutTask: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<Element?, Never>) {
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var values: [Element] = []
    private var waiters: [Waiter] = []
    private var isFinished = false

    func yield(_ value: Element) {
        let waiter: Waiter?
        lock.lock()
        if waiters.isEmpty {
            if !isFinished { values.append(value) }
            lock.unlock()
            return
        }
        waiter = waiters.removeFirst()
        lock.unlock()

        waiter?.timeoutTask?.cancel()
        waiter?.continuation.resume(returning: value)
    }

    func poll() -> Element? {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }

    func next(timeout: TimeInterval) async -> Element? {
        if let value = poll() { return value }
        if finished { return nil }

        return await withCheckedContinuation { continuation in
            let waiter = Waiter(continuation)
            lock.lock()
            if !values.isEmpty {
                let value = values.removeFirst()
                lock.unlock()
                continuation.resume(returning: value)
                return
            }
            if isFinished {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            waiter.timeoutTask = Task { [weak self, id = waiter.id] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                self?.timeout(id: id)
            }
            waiters.append(waiter)
            lock.unlock()
        }
    }

    private var finished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFinished
    }

    func finish() {
        lock.lock()
        isFinished = true
        let pending = waiters
        waiters.removeAll()
        values.removeAll()
        lock.unlock()

        for waiter in pending {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(returning: nil)
        }
    }

    private func timeout(id: UUID) {
        let waiter: Waiter?
        lock.lock()
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiter = waiters.remove(at: index)
        } else {
            waiter = nil
        }
        lock.unlock()

        waiter?.continuation.resume(returning: nil)
    }
}
#endif
