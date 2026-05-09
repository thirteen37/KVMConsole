@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@preconcurrency import VideoToolbox
import Foundation

enum H264DecoderError: Error, LocalizedError {
    case formatDescription(OSStatus)
    case decompressionSession(OSStatus)
    case blockBuffer(OSStatus)
    case sampleBuffer(OSStatus)
    case decode(OSStatus)

    var errorDescription: String? {
        switch self {
        case .formatDescription(let status): return "Could not create H.264 format description (\(status))."
        case .decompressionSession(let status): return "Could not create H.264 decoder session (\(status))."
        case .blockBuffer(let status): return "Could not create H.264 block buffer (\(status))."
        case .sampleBuffer(let status): return "Could not create H.264 sample buffer (\(status))."
        case .decode(let status): return "VideoToolbox failed to decode H.264 frame (\(status))."
        }
    }
}

private struct SendableSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
}

final class H264Decoder: @unchecked Sendable {
    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private let output: @MainActor (CMSampleBuffer) -> Void

    init(output: @escaping @MainActor (CMSampleBuffer) -> Void) {
        self.output = output
    }

    deinit {
        invalidate()
    }

    func decode(_ frame: H264StreamFrame) throws {
        let units = H264AnnexBParser.parseNALUnits(from: frame.payload)
        guard !units.isEmpty else { return }

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
            guard frame.isKeyFrame, sps != nil, pps != nil else { return }
            try createSession()
        }

        let sampleUnits = units.filter { !$0.isSPS && !$0.isPPS }
        guard !sampleUnits.isEmpty else { return }

        let sampleBuffer = try makeSampleBuffer(from: sampleUnits, timestampMicros: frame.timestampMicros)
        guard let decompressionSession else { return }

        let status = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: nil
        )
        guard status == noErr else { throw H264DecoderError.decode(status) }
    }

    func invalidate() {
        resetSession()
        sps = nil
        pps = nil
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
                    throw H264DecoderError.formatDescription(OSStatus(paramErr))
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

        guard let formatDescription else { throw H264DecoderError.formatDescription(OSStatus(paramErr)) }
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
        duration: CMTime
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

        let boxed = SendableSampleBuffer(value: decodedSampleBuffer)
        Task { @MainActor [output, boxed] in
            output(boxed.value)
        }
    }
}

private let decompressionOutputCallback: VTDecompressionOutputCallback = { refCon, _, status, _, imageBuffer, presentationTimeStamp, duration in
    guard let refCon else { return }
    let decoder = Unmanaged<H264Decoder>.fromOpaque(refCon).takeUnretainedValue()
    decoder.handleDecoded(
        status: status,
        imageBuffer: imageBuffer,
        presentationTimeStamp: presentationTimeStamp,
        duration: duration
    )
}
