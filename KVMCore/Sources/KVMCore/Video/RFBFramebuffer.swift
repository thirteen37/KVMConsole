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

    public func applyRaw(rect: RFBRectangle, bytes: Data) throws {
        guard let pixelBuffer else {
            throw RFBError.malformedMessage("framebuffer is not initialized")
        }
        let x = Int(rect.x)
        let y = Int(rect.y)
        let rectWidth = Int(rect.width)
        let rectHeight = Int(rect.height)
        try validateRect(x: x, y: y, width: rectWidth, height: rectHeight)

        let expectedByteCount = rectWidth * rectHeight * 4
        guard bytes.count == expectedByteCount else {
            throw RFBError.malformedMessage("raw rectangle has \(bytes.count) bytes; expected \(expectedByteCount)")
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw RFBError.malformedMessage("framebuffer has no base address")
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        bytes.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            for row in 0..<rectHeight {
                let destination = baseAddress
                    .advanced(by: (y + row) * bytesPerRow + x * 4)
                let rowSource = sourceBase.advanced(by: row * rectWidth * 4)
                memcpy(destination, rowSource, rectWidth * 4)
            }
        }
    }

    public func applyBGR(rect: RFBRectangle, bytes: Data) throws {
        let pixelCount = Int(rect.width) * Int(rect.height)
        guard bytes.count == pixelCount * 3 else {
            throw RFBError.malformedMessage("BGR rectangle has \(bytes.count) bytes; expected \(pixelCount * 3)")
        }
        var bgra = Data(count: pixelCount * 4)
        bgra.withUnsafeMutableBytes { destination in
            bytes.withUnsafeBytes { source in
                guard let destinationBase = destination.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let sourceBase = source.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return }
                for index in 0..<pixelCount {
                    destinationBase[index * 4] = sourceBase[index * 3]
                    destinationBase[index * 4 + 1] = sourceBase[index * 3 + 1]
                    destinationBase[index * 4 + 2] = sourceBase[index * 3 + 2]
                    destinationBase[index * 4 + 3] = 0
                }
            }
        }
        try applyRaw(rect: rect, bytes: bgra)
    }

    public func applyRGB(rect: RFBRectangle, bytes: Data) throws {
        let pixelCount = Int(rect.width) * Int(rect.height)
        guard bytes.count == pixelCount * 3 else {
            throw RFBError.malformedMessage("RGB rectangle has \(bytes.count) bytes; expected \(pixelCount * 3)")
        }
        var bgra = Data(count: pixelCount * 4)
        bgra.withUnsafeMutableBytes { destination in
            bytes.withUnsafeBytes { source in
                guard let destinationBase = destination.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let sourceBase = source.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return }
                for index in 0..<pixelCount {
                    destinationBase[index * 4] = sourceBase[index * 3 + 2]
                    destinationBase[index * 4 + 1] = sourceBase[index * 3 + 1]
                    destinationBase[index * 4 + 2] = sourceBase[index * 3]
                    destinationBase[index * 4 + 3] = 0
                }
            }
        }
        try applyRaw(rect: rect, bytes: bgra)
    }

    public func fill(rect: RFBRectangle, bgra: (UInt8, UInt8, UInt8, UInt8)) throws {
        let pixelCount = Int(rect.width) * Int(rect.height)
        var bytes = Data(count: pixelCount * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for index in 0..<pixelCount {
                base[index * 4] = bgra.0
                base[index * 4 + 1] = bgra.1
                base[index * 4 + 2] = bgra.2
                base[index * 4 + 3] = bgra.3
            }
        }
        try applyRaw(rect: rect, bytes: bytes)
    }

    public func applyCopyRect(rect: RFBRectangle, sourceX: UInt16, sourceY: UInt16) throws {
        guard let pixelBuffer else {
            throw RFBError.malformedMessage("framebuffer is not initialized")
        }
        let destinationX = Int(rect.x)
        let destinationY = Int(rect.y)
        let sourceX = Int(sourceX)
        let sourceY = Int(sourceY)
        let rectWidth = Int(rect.width)
        let rectHeight = Int(rect.height)
        try validateRect(x: destinationX, y: destinationY, width: rectWidth, height: rectHeight)
        try validateRect(x: sourceX, y: sourceY, width: rectWidth, height: rectHeight)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw RFBError.malformedMessage("framebuffer has no base address")
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var scratch = Data(count: rectWidth * rectHeight * 4)
        scratch.withUnsafeMutableBytes { scratchBuffer in
            guard let scratchBase = scratchBuffer.baseAddress else { return }
            for row in 0..<rectHeight {
                let source = baseAddress.advanced(by: (sourceY + row) * bytesPerRow + sourceX * 4)
                let destination = scratchBase.advanced(by: row * rectWidth * 4)
                memcpy(destination, source, rectWidth * 4)
            }
            for row in 0..<rectHeight {
                let source = scratchBase.advanced(by: row * rectWidth * 4)
                let destination = baseAddress.advanced(by: (destinationY + row) * bytesPerRow + destinationX * 4)
                memcpy(destination, source, rectWidth * 4)
            }
        }
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
