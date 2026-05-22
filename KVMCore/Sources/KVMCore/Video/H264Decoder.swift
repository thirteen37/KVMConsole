@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@preconcurrency import VideoToolbox
import Foundation

public enum H264DecoderError: Error, LocalizedError {
    case formatDescription(OSStatus)
    case decompressionSession(OSStatus)
    case blockBuffer(OSStatus)
    case sampleBuffer(OSStatus)
    case decode(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .formatDescription(let status): return "Could not create H.264 format description (\(status))."
        case .decompressionSession(let status): return "Could not create H.264 decoder session (\(status))."
        case .blockBuffer(let status): return "Could not create H.264 block buffer (\(status))."
        case .sampleBuffer(let status): return "Could not create H.264 sample buffer (\(status))."
        case .decode(let status): return "VideoToolbox failed to decode H.264 frame (\(status))."
        }
    }
}

private let invalidParameterStatus = OSStatus(-50)

enum H264FrameContinuityAction: Equatable {
    case decode
    case decodeThroughDiscontinuity
    case resetAndDecodeKeyframe
}

struct H264FrameContinuityGate {
    private(set) var lastSequenceNumber: UInt64?

    mutating func inspect(_ frame: H264StreamFrame, isKeyFrame: Bool) -> H264FrameContinuityAction {
        let hasDiscontinuity = lastSequenceNumber.map { frame.sequenceNumber != $0 &+ 1 } ?? false
        lastSequenceNumber = frame.sequenceNumber

        guard hasDiscontinuity else {
            return .decode
        }

        if isKeyFrame {
            return .resetAndDecodeKeyframe
        }

        return .decodeThroughDiscontinuity
    }

    mutating func reset() {
        lastSequenceNumber = nil
    }
}

public final class H264Decoder: @unchecked Sendable {
    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var continuityGate = H264FrameContinuityGate()
    private let output: @Sendable (CMSampleBuffer) -> Void

    public init(output: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.output = output
    }

    deinit {
        invalidate()
    }

    public func decode(_ frame: H264StreamFrame) throws {
        let units = H264AnnexBParser.parseNALUnits(from: frame.payload)
        guard !units.isEmpty else { return }

        let isKeyFrame = frame.isKeyFrame || units.contains { $0.isIDR }
        switch continuityGate.inspect(frame, isKeyFrame: isKeyFrame) {
        case .decode:
            break
        case .resetAndDecodeKeyframe:
            KVMLog.video.info(
                "H.264 stream discontinuity at appSequence=\(frame.sequenceNumber, privacy: .public); resetting decoder at keyframe"
            )
            resetSession()
        case .decodeThroughDiscontinuity:
            KVMLog.video.info(
                "H.264 stream discontinuity at appSequence=\(frame.sequenceNumber, privacy: .public); decoding through because no keyframe was available"
            )
        }

        var parameterSetsChanged = false
        for unit in units {
            if unit.isSPS, sps != unit.data {
                sps = unit.data
                parameterSetsChanged = true
            } else if unit.isPPS, pps != unit.data {
                pps = unit.data
                parameterSetsChanged = true
            }
        }

        if parameterSetsChanged {
            resetSession()
        }

        if decompressionSession == nil {
            guard isKeyFrame, sps != nil, pps != nil else { return }
            try createSession()
        }

        let sampleUnits = units.filter { !$0.isSPS && !$0.isPPS }
        guard !sampleUnits.isEmpty else { return }

        let sampleBuffer = try makeSampleBuffer(from: sampleUnits, timestampMicros: frame.timestampMicros)
        guard let decompressionSession else { return }

        let context = Unmanaged.passRetained(
            H264FrameDecodeContext(wireArrivalHostTime: frame.wireArrivalHostTime)
        )
        let status = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: context.toOpaque(),
            infoFlagsOut: nil
        )
        guard status == noErr else {
            // VT did not accept the frame; release the context we retained.
            context.release()
            throw H264DecoderError.decode(status)
        }
    }

    public func invalidate() {
        resetSession()
        sps = nil
        pps = nil
        continuityGate.reset()
    }

    private func resetSession() {
        if let decompressionSession {
            VTDecompressionSessionInvalidate(decompressionSession)
        }
        decompressionSession = nil
        formatDescription = nil
    }

    private func createSession() throws {
        guard let sps, let pps else { return }

        var newFormatDescription: CMVideoFormatDescription?
        let formatStatus = try sps.withUnsafeBytes { spsBytes in
            try pps.withUnsafeBytes { ppsBytes in
                guard
                    let spsBase = spsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    let ppsBase = ppsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else {
                    throw H264DecoderError.formatDescription(invalidParameterStatus)
                }

                var parameterSetPointers = [spsBase, ppsBase]
                var parameterSetSizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &parameterSetPointers,
                    parameterSetSizes: &parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &newFormatDescription
                )
            }
        }
        guard formatStatus == noErr, let newFormatDescription else {
            throw H264DecoderError.formatDescription(formatStatus)
        }

        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decompressionOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let imageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        var newSession: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: newFormatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &newSession
        )
        guard sessionStatus == noErr, let newSession else {
            throw H264DecoderError.decompressionSession(sessionStatus)
        }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        var threadCountValue: Int32 = 1
        if let threadCount = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &threadCountValue) {
            VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_ThreadCount, value: threadCount)
        }

        formatDescription = newFormatDescription
        decompressionSession = newSession
    }

    private func makeSampleBuffer(from units: [H264NALUnit], timestampMicros: UInt64) throws -> CMSampleBuffer {
        var sampleData = Data()
        for unit in units {
            var length = UInt32(unit.data.count).bigEndian
            withUnsafeBytes(of: &length) { sampleData.append(contentsOf: $0) }
            sampleData.append(unit.data)
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sampleData.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sampleData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { throw H264DecoderError.blockBuffer(status) }

        status = sampleData.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: sampleData.count
            )
        }
        guard status == noErr else { throw H264DecoderError.blockBuffer(status) }

        guard let formatDescription else { throw H264DecoderError.formatDescription(invalidParameterStatus) }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(timestampMicros), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = sampleData.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw H264DecoderError.sampleBuffer(status) }

        return sampleBuffer
    }

    fileprivate func handleDecoded(
        status: OSStatus,
        imageBuffer: CVImageBuffer?,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        wireArrivalHostTime: CMTime?
    ) {
        guard status == noErr, let imageBuffer else { return }

        var imageFormatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &imageFormatDescription
        )
        guard formatStatus == noErr, let imageFormatDescription else { return }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var decodedSampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: imageFormatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &decodedSampleBuffer
        )
        guard sampleStatus == noErr, let decodedSampleBuffer else { return }

        markDisplayImmediately(decodedSampleBuffer)
        if let wireArrivalHostTime {
            SampleBufferLatencyTag.attachWireArrivalHostTime(wireArrivalHostTime, to: decodedSampleBuffer)
        }
        output(decodedSampleBuffer)
    }

    private func markDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0,
            let attachment = CFArrayGetValueAtIndex(attachments, 0)
        else { return }

        let attachmentDictionary = unsafeBitCast(attachment, to: CFMutableDictionary.self)
        CFDictionarySetValue(
            attachmentDictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}

private let decompressionOutputCallback: VTDecompressionOutputCallback = { refCon, sourceFrameRefCon, status, _, imageBuffer, presentationTimeStamp, duration in
    var wireArrivalHostTime: CMTime?
    if let sourceFrameRefCon {
        let context = Unmanaged<H264FrameDecodeContext>.fromOpaque(sourceFrameRefCon).takeRetainedValue()
        wireArrivalHostTime = context.wireArrivalHostTime
    }
    guard let refCon else { return }
    let decoder = Unmanaged<H264Decoder>.fromOpaque(refCon).takeUnretainedValue()
    decoder.handleDecoded(
        status: status,
        imageBuffer: imageBuffer,
        presentationTimeStamp: presentationTimeStamp,
        duration: duration,
        wireArrivalHostTime: wireArrivalHostTime
    )
}

final class H264FrameDecodeContext {
    let wireArrivalHostTime: CMTime?

    init(wireArrivalHostTime: CMTime?) {
        self.wireArrivalHostTime = wireArrivalHostTime
    }
}
