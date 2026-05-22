#if os(macOS)
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation

/// Lightweight read-only snapshot of a rectangular region of a `CVImageBuffer`.
/// Used by `InputLatencyRunner` to detect on-screen changes after an input
/// event. Supports both 32BGRA (RFB framebuffer) and 420 biplanar YUV
/// (H.264 decoded output) — for YUV only the luma plane is read.
struct PixelRegion: Sendable {
    enum Format: Sendable {
        case bgra
        case lumaOnly
    }

    let format: Format
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: Data

    /// Average per-byte absolute delta against another region of the same
    /// format and size.
    func meanAbsoluteDifference(against other: PixelRegion) -> Double {
        precondition(format == other.format)
        precondition(width == other.width && height == other.height)
        return bytes.withUnsafeBytes { lhs in
            other.bytes.withUnsafeBytes { rhs in
                guard
                    let lhsBase = lhs.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    let rhsBase = rhs.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return 0.0 }
                let count = Swift.min(lhs.count, rhs.count)
                if count == 0 { return 0.0 }
                var total: UInt64 = 0
                for i in 0..<count {
                    let a = Int(lhsBase[i])
                    let b = Int(rhsBase[i])
                    total &+= UInt64(abs(a - b))
                }
                return Double(total) / Double(count)
            }
        }
    }
}

enum PixelRegionExtractor {
    /// Reads a `regionSide × regionSide` patch centered on `(centerX, centerY)`
    /// (in framebuffer pixel coordinates) from `pixelBuffer`. Returns nil if
    /// the format is unsupported or the patch falls outside the framebuffer.
    static func extract(
        from pixelBuffer: CVPixelBuffer,
        centerX: Int,
        centerY: Int,
        regionSide: Int
    ) -> PixelRegion? {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let bufWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufHeight = CVPixelBufferGetHeight(pixelBuffer)

        let half = regionSide / 2
        let originX = Swift.max(0, Swift.min(bufWidth - regionSide, centerX - half))
        let originY = Swift.max(0, Swift.min(bufHeight - regionSide, centerY - half))
        guard originX >= 0, originY >= 0, originX + regionSide <= bufWidth, originY + regionSide <= bufHeight else {
            return nil
        }

        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard lockStatus == kCVReturnSuccess else { return nil }

        switch pixelFormat {
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB, kCVPixelFormatType_32RGBA:
            return extractInterleavedBGRA(
                pixelBuffer: pixelBuffer,
                originX: originX,
                originY: originY,
                regionSide: regionSide
            )
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return extractLumaPlane(
                pixelBuffer: pixelBuffer,
                originX: originX,
                originY: originY,
                regionSide: regionSide
            )
        default:
            return nil
        }
    }

    private static func extractInterleavedBGRA(
        pixelBuffer: CVPixelBuffer,
        originX: Int,
        originY: Int,
        regionSide: Int
    ) -> PixelRegion? {
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var bytes = Data(count: regionSide * regionSide * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let dst = buffer.baseAddress else { return }
            for row in 0..<regionSide {
                let src = base.advanced(by: (originY + row) * bytesPerRow + originX * 4)
                let rowDst = dst.advanced(by: row * regionSide * 4)
                memcpy(rowDst, src, regionSide * 4)
            }
        }
        return PixelRegion(
            format: .bgra,
            width: regionSide,
            height: regionSide,
            bytesPerRow: regionSide * 4,
            bytes: bytes
        )
    }

    private static func extractLumaPlane(
        pixelBuffer: CVPixelBuffer,
        originX: Int,
        originY: Int,
        regionSide: Int
    ) -> PixelRegion? {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        var bytes = Data(count: regionSide * regionSide)
        bytes.withUnsafeMutableBytes { buffer in
            guard let dst = buffer.baseAddress else { return }
            for row in 0..<regionSide {
                let src = base.advanced(by: (originY + row) * bytesPerRow + originX)
                let rowDst = dst.advanced(by: row * regionSide)
                memcpy(rowDst, src, regionSide)
            }
        }
        return PixelRegion(
            format: .lumaOnly,
            width: regionSide,
            height: regionSide,
            bytesPerRow: regionSide,
            bytes: bytes
        )
    }
}
#endif
