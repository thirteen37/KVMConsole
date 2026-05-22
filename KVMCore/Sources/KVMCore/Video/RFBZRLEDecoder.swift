import Foundation

public final class RFBZRLEDecoder: @unchecked Sendable {
    private let inflater: RFBZlibInflater
    private var lastPalette: [ZRLEColor] = []

    public init() throws {
        self.inflater = try RFBZlibInflater()
    }

    public func apply(rect: RFBRectangle, compressedData: Data, to framebuffer: RFBFramebuffer) throws {
        try framebuffer.withLockedBuffer { writer in
            try apply(rect: rect, compressedData: compressedData, to: writer)
        }
    }

    public func apply(rect: RFBRectangle, compressedData: Data, to writer: RFBFramebuffer.Writer) throws {
        let expected = Int(rect.width) * Int(rect.height) * 4 + 4096
        let data = try inflater.inflate(compressedData, expectedByteCount: expected)
        var reader = RFBByteReader(data)

        let rectX = Int(rect.x)
        let rectY = Int(rect.y)
        let rectWidth = Int(rect.width)
        let rectHeight = Int(rect.height)
        let bytesPerRow = writer.bytesPerRow
        let outputBase = writer.baseAddress.assumingMemoryBound(to: UInt8.self)

        for tileY in stride(from: 0, to: rectHeight, by: 64) {
            for tileX in stride(from: 0, to: rectWidth, by: 64) {
                let tileWidth = min(64, rectWidth - tileX)
                let tileHeight = min(64, rectHeight - tileY)
                try decodeTile(
                    reader: &reader,
                    output: outputBase,
                    bytesPerRow: bytesPerRow,
                    tileX: rectX + tileX,
                    tileY: rectY + tileY,
                    tileWidth: tileWidth,
                    tileHeight: tileHeight
                )
            }
        }
    }

    private func decodeTile(
        reader: inout RFBByteReader,
        output: UnsafeMutablePointer<UInt8>,
        bytesPerRow: Int,
        tileX: Int,
        tileY: Int,
        tileWidth: Int,
        tileHeight: Int
    ) throws {
        let subencoding = try reader.readUInt8()
        let isRLE = (subencoding & 0x80) != 0
        let paletteSize = Int(subencoding & 0x7f)

        switch (isRLE, paletteSize) {
        case (false, 0):
            try decodeRawTile(reader: &reader, output: output, bytesPerRow: bytesPerRow, tileX: tileX, tileY: tileY, tileWidth: tileWidth, tileHeight: tileHeight)
        case (false, 1):
            let color = try readColor(reader: &reader)
            writeSolid(color, output: output, bytesPerRow: bytesPerRow, tileX: tileX, tileY: tileY, tileWidth: tileWidth, tileHeight: tileHeight)
            lastPalette = [color]
        case (false, 2...16):
            let palette = try readPalette(reader: &reader, count: paletteSize)
            lastPalette = palette
            try decodePackedPalette(reader: &reader, palette: palette, output: output, bytesPerRow: bytesPerRow, tileX: tileX, tileY: tileY, tileWidth: tileWidth, tileHeight: tileHeight)
        case (false, 127):
            try decodePackedPalette(reader: &reader, palette: lastPalette, output: output, bytesPerRow: bytesPerRow, tileX: tileX, tileY: tileY, tileWidth: tileWidth, tileHeight: tileHeight)
        case (true, 0):
            try decodePlainRLE(reader: &reader, output: output, bytesPerRow: bytesPerRow, tileX: tileX, tileY: tileY, tileWidth: tileWidth, tileHeight: tileHeight)
        case (true, 1):
            try decodePaletteRLE(reader: &reader, palette: lastPalette, output: output, bytesPerRow: bytesPerRow, tileX: tileX, tileY: tileY, tileWidth: tileWidth, tileHeight: tileHeight)
        case (true, 2...127):
            let palette = try readPalette(reader: &reader, count: paletteSize)
            lastPalette = palette
            try decodePaletteRLE(reader: &reader, palette: palette, output: output, bytesPerRow: bytesPerRow, tileX: tileX, tileY: tileY, tileWidth: tileWidth, tileHeight: tileHeight)
        default:
            throw RFBError.malformedMessage("unsupported ZRLE subencoding \(subencoding)")
        }
    }

    private func readColor(reader: inout RFBByteReader) throws -> ZRLEColor {
        ZRLEColor(
            byte0: try reader.readUInt8(),
            byte1: try reader.readUInt8(),
            byte2: try reader.readUInt8()
        )
    }

    private func readPalette(reader: inout RFBByteReader, count: Int) throws -> [ZRLEColor] {
        var palette: [ZRLEColor] = []
        palette.reserveCapacity(count)
        for _ in 0..<count {
            palette.append(try readColor(reader: &reader))
        }
        return palette
    }

    private func decodeRawTile(
        reader: inout RFBByteReader,
        output: UnsafeMutablePointer<UInt8>,
        bytesPerRow: Int,
        tileX: Int,
        tileY: Int,
        tileWidth: Int,
        tileHeight: Int
    ) throws {
        let bytes = try reader.readData(count: tileWidth * tileHeight * 3)
        bytes.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for row in 0..<tileHeight {
                let dst = output.advanced(by: (tileY + row) * bytesPerRow + tileX * 4)
                let src = sourceBase.advanced(by: row * tileWidth * 3)
                for col in 0..<tileWidth {
                    dst[col * 4]     = src[col * 3]
                    dst[col * 4 + 1] = src[col * 3 + 1]
                    dst[col * 4 + 2] = src[col * 3 + 2]
                    dst[col * 4 + 3] = 0
                }
            }
        }
    }

    private func decodePackedPalette(
        reader: inout RFBByteReader,
        palette: [ZRLEColor],
        output: UnsafeMutablePointer<UInt8>,
        bytesPerRow: Int,
        tileX: Int,
        tileY: Int,
        tileWidth: Int,
        tileHeight: Int
    ) throws {
        guard !palette.isEmpty else { throw RFBError.malformedMessage("ZRLE palette is empty") }
        let bitsPerPixel = palette.count <= 2 ? 1 : (palette.count <= 4 ? 2 : 4)
        let mask = UInt8((1 << bitsPerPixel) - 1)
        let rowBytes = (tileWidth * bitsPerPixel + 7) / 8

        for row in 0..<tileHeight {
            let rowData = try reader.readData(count: rowBytes)
            let dstRow = output.advanced(by: (tileY + row) * bytesPerRow + tileX * 4)
            try rowData.withUnsafeBytes { sourceBuffer in
                guard let sourceBase = sourceBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                var col = 0
                for byteIndex in 0..<rowBytes {
                    let byte = sourceBase[byteIndex]
                    var shift = 8 - bitsPerPixel
                    while shift >= 0, col < tileWidth {
                        let index = Int((byte >> UInt8(shift)) & mask)
                        guard index < palette.count else {
                            throw RFBError.malformedMessage("ZRLE palette index out of range")
                        }
                        let color = palette[index]
                        let pixel = dstRow.advanced(by: col * 4)
                        pixel[0] = color.byte0
                        pixel[1] = color.byte1
                        pixel[2] = color.byte2
                        pixel[3] = 0
                        col += 1
                        shift -= bitsPerPixel
                    }
                }
            }
        }
    }

    private func decodePlainRLE(
        reader: inout RFBByteReader,
        output: UnsafeMutablePointer<UInt8>,
        bytesPerRow: Int,
        tileX: Int,
        tileY: Int,
        tileWidth: Int,
        tileHeight: Int
    ) throws {
        var rowIndex = 0
        var colIndex = 0
        let total = tileWidth * tileHeight
        var remaining = total
        while remaining > 0 {
            let color = try readColor(reader: &reader)
            var runLength = min(try readRunLength(reader: &reader), remaining)
            remaining -= runLength
            while runLength > 0 {
                let canFit = min(runLength, tileWidth - colIndex)
                let dst = output.advanced(by: (tileY + rowIndex) * bytesPerRow + (tileX + colIndex) * 4)
                writeRun(color: color, destination: dst, count: canFit)
                colIndex += canFit
                if colIndex == tileWidth {
                    colIndex = 0
                    rowIndex += 1
                }
                runLength -= canFit
            }
        }
    }

    private func decodePaletteRLE(
        reader: inout RFBByteReader,
        palette: [ZRLEColor],
        output: UnsafeMutablePointer<UInt8>,
        bytesPerRow: Int,
        tileX: Int,
        tileY: Int,
        tileWidth: Int,
        tileHeight: Int
    ) throws {
        guard !palette.isEmpty else { throw RFBError.malformedMessage("ZRLE palette is empty") }
        var rowIndex = 0
        var colIndex = 0
        let total = tileWidth * tileHeight
        var remaining = total
        while remaining > 0 {
            let indexByte = try reader.readUInt8()
            let index = Int(indexByte & 0x7f)
            guard index < palette.count else { throw RFBError.malformedMessage("ZRLE palette index out of range") }
            let color = palette[index]
            var runLength = (indexByte & 0x80) == 0 ? 1 : try readRunLength(reader: &reader)
            runLength = min(runLength, remaining)
            remaining -= runLength
            while runLength > 0 {
                let canFit = min(runLength, tileWidth - colIndex)
                let dst = output.advanced(by: (tileY + rowIndex) * bytesPerRow + (tileX + colIndex) * 4)
                writeRun(color: color, destination: dst, count: canFit)
                colIndex += canFit
                if colIndex == tileWidth {
                    colIndex = 0
                    rowIndex += 1
                }
                runLength -= canFit
            }
        }
    }

    private func readRunLength(reader: inout RFBByteReader) throws -> Int {
        var length = 1
        while true {
            let byte = Int(try reader.readUInt8())
            length += byte
            if byte != 255 { break }
        }
        return length
    }

    /// Writes `count` BGRA pixels of the same color starting at `destination`.
    /// Uses `memset_pattern4` so a single instruction broadcasts the
    /// 32-bit pixel pattern across the entire run.
    private func writeRun(color: ZRLEColor, destination: UnsafeMutablePointer<UInt8>, count: Int) {
        var pattern: UInt32 =
            UInt32(color.byte0)
            | (UInt32(color.byte1) << 8)
            | (UInt32(color.byte2) << 16)
        memset_pattern4(UnsafeMutableRawPointer(destination), &pattern, count * 4)
    }

    private func writeSolid(
        _ color: ZRLEColor,
        output: UnsafeMutablePointer<UInt8>,
        bytesPerRow: Int,
        tileX: Int,
        tileY: Int,
        tileWidth: Int,
        tileHeight: Int
    ) {
        var pattern: UInt32 =
            UInt32(color.byte0)
            | (UInt32(color.byte1) << 8)
            | (UInt32(color.byte2) << 16)
        for row in 0..<tileHeight {
            let dst = output.advanced(by: (tileY + row) * bytesPerRow + tileX * 4)
            memset_pattern4(UnsafeMutableRawPointer(dst), &pattern, tileWidth * 4)
        }
    }
}

private struct ZRLEColor {
    let byte0: UInt8
    let byte1: UInt8
    let byte2: UInt8
}
