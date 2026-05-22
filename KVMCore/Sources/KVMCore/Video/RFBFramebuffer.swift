@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation

public final class RFBFramebuffer: @unchecked Sendable {
    public private(set) var width: Int = 0
    public private(set) var height: Int = 0

    private var pixelBuffer: CVPixelBuffer?
    private var formatDescription: CMVideoFormatDescription?

    public init() {}

    public func resize(width: Int, height: Int) throws {
        guard width > 0, height > 0 else {
            throw RFBError.malformedMessage("invalid framebuffer size \(width)x\(height)")
        }

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        var newPixelBuffer: CVPixelBuffer?
        let pixelStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &newPixelBuffer
        )
        guard pixelStatus == kCVReturnSuccess, let newPixelBuffer else {
            throw RFBError.malformedMessage("failed to allocate framebuffer")
        }

        var newFormatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: newPixelBuffer,
            formatDescriptionOut: &newFormatDescription
        )
        guard formatStatus == noErr, let newFormatDescription else {
            throw RFBError.malformedMessage("failed to create framebuffer format description")
        }

        CVPixelBufferLockBaseAddress(newPixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(newPixelBuffer) {
            memset(baseAddress, 0, CVPixelBufferGetBytesPerRow(newPixelBuffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(newPixelBuffer, [])

        self.width = width
        self.height = height
        self.pixelBuffer = newPixelBuffer
        self.formatDescription = newFormatDescription
    }

    /// Locks the framebuffer once and exposes a `Writer` that aggregates
    /// rectangle writes for the duration of an RFB framebuffer-update
    /// message. The hot path uses this so we incur a single
    /// `CVPixelBufferLockBaseAddress` / `Unlock` pair per update instead of
    /// one per rectangle.
    public func withLockedBuffer<R>(_ body: (Writer) throws -> R) throws -> R {
        guard let pixelBuffer else {
            throw RFBError.malformedMessage("framebuffer is not initialized")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw RFBError.malformedMessage("framebuffer has no base address")
        }
        let writer = Writer(
            baseAddress: baseAddress,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            width: width,
            height: height
        )
        return try body(writer)
    }

    public func applyRaw(rect: RFBRectangle, bytes: Data) throws {
        try withLockedBuffer { try $0.applyRaw(rect: rect, bytes: bytes) }
    }

    public func applyBGR(rect: RFBRectangle, bytes: Data) throws {
        try withLockedBuffer { try $0.applyBGR(rect: rect, bytes: bytes) }
    }

    public func applyRGB(rect: RFBRectangle, bytes: Data) throws {
        try withLockedBuffer { try $0.applyRGB(rect: rect, bytes: bytes) }
    }

    public func fill(rect: RFBRectangle, bgra: (UInt8, UInt8, UInt8, UInt8)) throws {
        try withLockedBuffer { try $0.fill(rect: rect, bgra: bgra) }
    }

    public func applyCopyRect(rect: RFBRectangle, sourceX: UInt16, sourceY: UInt16) throws {
        try withLockedBuffer { try $0.applyCopyRect(rect: rect, sourceX: sourceX, sourceY: sourceY) }
    }

    public func makeSampleBuffer(wireArrivalHostTime: CMTime? = nil) throws -> CMSampleBuffer {
        guard let pixelBuffer, let formatDescription else {
            throw RFBError.malformedMessage("framebuffer is not initialized")
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw RFBError.malformedMessage("failed to create sample buffer")
        }
        markDisplayImmediately(sampleBuffer)
        if let wireArrivalHostTime {
            SampleBufferLatencyTag.attachWireArrivalHostTime(wireArrivalHostTime, to: sampleBuffer)
        }
        return sampleBuffer
    }

    private func markDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: true
            ),
            CFArrayGetCount(attachments) > 0
        else { return }

        let attachment = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            attachment,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    public func pixelBytes() throws -> Data {
        guard let pixelBuffer else {
            throw RFBError.malformedMessage("framebuffer is not initialized")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw RFBError.malformedMessage("framebuffer has no base address")
        }
        var data = Data(count: width * height * 4)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        data.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            for row in 0..<height {
                memcpy(
                    destinationBase.advanced(by: row * width * 4),
                    baseAddress.advanced(by: row * bytesPerRow),
                    width * 4
                )
            }
        }
        return data
    }
}

extension RFBFramebuffer {
    /// Direct access to the live BGRA pixel buffer for the duration of a
    /// `withLockedBuffer` body. Decoders write through this to skip the
    /// per-rectangle locks and intermediate `Data` allocations that the
    /// pre-optimization code path used.
    public struct Writer {
        public let baseAddress: UnsafeMutableRawPointer
        public let bytesPerRow: Int
        public let width: Int
        public let height: Int

        init(baseAddress: UnsafeMutableRawPointer, bytesPerRow: Int, width: Int, height: Int) {
            self.baseAddress = baseAddress
            self.bytesPerRow = bytesPerRow
            self.width = width
            self.height = height
        }

        public func applyRaw(rect: RFBRectangle, bytes: Data) throws {
            let x = Int(rect.x)
            let y = Int(rect.y)
            let rectWidth = Int(rect.width)
            let rectHeight = Int(rect.height)
            try validateRect(x: x, y: y, width: rectWidth, height: rectHeight)

            let expectedByteCount = rectWidth * rectHeight * 4
            guard bytes.count == expectedByteCount else {
                throw RFBError.malformedMessage("raw rectangle has \(bytes.count) bytes; expected \(expectedByteCount)")
            }

            bytes.withUnsafeBytes { source in
                guard let sourceBase = source.baseAddress else { return }
                for row in 0..<rectHeight {
                    let destination = baseAddress.advanced(by: (y + row) * bytesPerRow + x * 4)
                    let rowSource = sourceBase.advanced(by: row * rectWidth * 4)
                    memcpy(destination, rowSource, rectWidth * 4)
                }
            }
        }

        public func applyBGR(rect: RFBRectangle, bytes: Data) throws {
            let x = Int(rect.x)
            let y = Int(rect.y)
            let rectWidth = Int(rect.width)
            let rectHeight = Int(rect.height)
            try validateRect(x: x, y: y, width: rectWidth, height: rectHeight)

            let pixelCount = rectWidth * rectHeight
            guard bytes.count == pixelCount * 3 else {
                throw RFBError.malformedMessage("BGR rectangle has \(bytes.count) bytes; expected \(pixelCount * 3)")
            }

            bytes.withUnsafeBytes { source in
                guard let sourceBase = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for row in 0..<rectHeight {
                    let destinationRow = baseAddress
                        .advanced(by: (y + row) * bytesPerRow + x * 4)
                        .assumingMemoryBound(to: UInt8.self)
                    let sourceRow = sourceBase.advanced(by: row * rectWidth * 3)
                    for col in 0..<rectWidth {
                        destinationRow[col * 4]     = sourceRow[col * 3]
                        destinationRow[col * 4 + 1] = sourceRow[col * 3 + 1]
                        destinationRow[col * 4 + 2] = sourceRow[col * 3 + 2]
                        destinationRow[col * 4 + 3] = 0
                    }
                }
            }
        }

        public func applyRGB(rect: RFBRectangle, bytes: Data) throws {
            let x = Int(rect.x)
            let y = Int(rect.y)
            let rectWidth = Int(rect.width)
            let rectHeight = Int(rect.height)
            try validateRect(x: x, y: y, width: rectWidth, height: rectHeight)

            let pixelCount = rectWidth * rectHeight
            guard bytes.count == pixelCount * 3 else {
                throw RFBError.malformedMessage("RGB rectangle has \(bytes.count) bytes; expected \(pixelCount * 3)")
            }

            bytes.withUnsafeBytes { source in
                guard let sourceBase = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for row in 0..<rectHeight {
                    let destinationRow = baseAddress
                        .advanced(by: (y + row) * bytesPerRow + x * 4)
                        .assumingMemoryBound(to: UInt8.self)
                    let sourceRow = sourceBase.advanced(by: row * rectWidth * 3)
                    for col in 0..<rectWidth {
                        destinationRow[col * 4]     = sourceRow[col * 3 + 2]
                        destinationRow[col * 4 + 1] = sourceRow[col * 3 + 1]
                        destinationRow[col * 4 + 2] = sourceRow[col * 3]
                        destinationRow[col * 4 + 3] = 0
                    }
                }
            }
        }

        public func fill(rect: RFBRectangle, bgra: (UInt8, UInt8, UInt8, UInt8)) throws {
            let x = Int(rect.x)
            let y = Int(rect.y)
            let rectWidth = Int(rect.width)
            let rectHeight = Int(rect.height)
            try validateRect(x: x, y: y, width: rectWidth, height: rectHeight)

            var pattern: UInt32 =
                UInt32(bgra.0)
                | (UInt32(bgra.1) << 8)
                | (UInt32(bgra.2) << 16)
                | (UInt32(bgra.3) << 24)
            for row in 0..<rectHeight {
                let destination = baseAddress.advanced(by: (y + row) * bytesPerRow + x * 4)
                memset_pattern4(destination, &pattern, rectWidth * 4)
            }
        }

        public func applyCopyRect(rect: RFBRectangle, sourceX: UInt16, sourceY: UInt16) throws {
            let destinationX = Int(rect.x)
            let destinationY = Int(rect.y)
            let srcX = Int(sourceX)
            let srcY = Int(sourceY)
            let rectWidth = Int(rect.width)
            let rectHeight = Int(rect.height)
            try validateRect(x: destinationX, y: destinationY, width: rectWidth, height: rectHeight)
            try validateRect(x: srcX, y: srcY, width: rectWidth, height: rectHeight)

            // Detect overlap. If destination and source ranges don't overlap on
            // either axis we can plain `memcpy`. Otherwise pick a row iteration
            // direction that doesn't clobber rows we still need to read, and
            // use `memmove` (handles within-row overlap).
            let columnsOverlap = destinationX < srcX + rectWidth && srcX < destinationX + rectWidth
            let rowsOverlap = destinationY < srcY + rectHeight && srcY < destinationY + rectHeight

            if !(columnsOverlap && rowsOverlap) {
                for row in 0..<rectHeight {
                    let source = baseAddress.advanced(by: (srcY + row) * bytesPerRow + srcX * 4)
                    let destination = baseAddress.advanced(by: (destinationY + row) * bytesPerRow + destinationX * 4)
                    memcpy(destination, source, rectWidth * 4)
                }
                return
            }

            let rows: StrideThrough<Int> = destinationY > srcY
                ? stride(from: rectHeight - 1, through: 0, by: -1)
                : stride(from: 0, through: rectHeight - 1, by: 1)
            for row in rows {
                let source = baseAddress.advanced(by: (srcY + row) * bytesPerRow + srcX * 4)
                let destination = baseAddress.advanced(by: (destinationY + row) * bytesPerRow + destinationX * 4)
                memmove(destination, source, rectWidth * 4)
            }
        }

        public func validate(rect: RFBRectangle) throws {
            try validateRect(
                x: Int(rect.x),
                y: Int(rect.y),
                width: Int(rect.width),
                height: Int(rect.height)
            )
        }

        private func validateRect(x: Int, y: Int, width: Int, height: Int) throws {
            guard
                x >= 0,
                y >= 0,
                width >= 0,
                height >= 0,
                x + width <= self.width,
                y + height <= self.height
            else {
                throw RFBError.malformedMessage("rectangle is outside framebuffer")
            }
        }
    }
}
