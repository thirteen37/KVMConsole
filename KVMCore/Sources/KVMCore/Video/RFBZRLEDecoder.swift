import Foundation

public final class RFBZRLEDecoder: @unchecked Sendable {
    private let inflater: RFBZlibInflater
    private var lastPalette: [Data] = []

    public init() throws {
        self.inflater = try RFBZlibInflater()
    }

    public func apply(rect: RFBRectangle, compressedData: Data, to framebuffer: RFBFramebuffer) throws {
        let expected = Int(rect.width) * Int(rect.height) * 4 + 4096
        let data = try inflater.inflate(compressedData, expectedByteCount: expected)
        var reader = RFBByteReader(data)
        var output = Data(count: Int(rect.width) * Int(rect.height) * 3)

        for tileY in stride(from: 0, to: Int(rect.height), by: 64) {
            for tileX in stride(from: 0, to: Int(rect.width), by: 64) {
                let tileWidth = min(64, Int(rect.width) - tileX)
                let tileHeight = min(64, Int(rect.height) - tileY)
                try decodeTile(
                    reader: &reader,
                    output: &output,
                    rectWidth: Int(rect.width),
                    tileX: tileX,
                    tileY: tileY,
                    tileWidth: tileWidth,
                    tileHeight: tileHeight
                )
            }
        }

        try framebuffer.applyBGR(rect: rect, bytes: output)
    }

    private func decodeTile(
        reader: inout RFBByteReader,
        output: inout Data,
        rectWidth: Int,
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
            let bytes = try reader.readData(count: tileWidth * tileHeight * 3)
            writeTile(bytes, output: &output, rectWidth: rectWidth, tileX: tileX, tileY: tileY, tileWidth: tileWidth, tileHeight: tileHeight)
        case (false, 1):
            let color = try reader.readData(count: 3)
            writeSolid(color, output: &output, rectWidth: rectWidth, tileX: tileX, tileY: tileY, tileWidth: tileWidth, tileHeight: tileHeight)
            lastPalette = [color]
        case (false, 2...16):
            let palette = try readPalette(reader: &reader, count: paletteSize)
            lastPalette = palette
            try decodePackedPalette(reader: &reader, palette: palette, output: &output, rectWidth: rectWidth, tileX: tileX, tileY: tileY, tileWidth: tileWidth, tileHeight: tileHeight)
        case (false, 127):
            try decodePackedPalette(reader: &reader, palette: lastPalette, output: &output, rectWidth: rectWidth, tileX: tileX, tileY: tileY, tileWidth: tileWidth, tileHeight: tileHeight)
        case (true, 0):
            try decodePlainRLE(reader: &reader, output: &output, rectWidth: rectWidth, tileX: tileX, tileY: tileY, tileWidth: tileWidth, tileHeight: tileHeight)
        case (true, 1):
            try decodePaletteRLE(reader: &reader, palette: lastPalette, output: &output, rectWidth: rectWidth, tileX: tileX, tileY: tileY, tileWidth: tileWidth, tileHeight: tileHeight)
        case (true, 2...127):
            let palette = try readPalette(reader: &reader, count: paletteSize)
            lastPalette = palette
            try decodePaletteRLE(reader: &reader, palette: palette, output: &output, rectWidth: rectWidth, tileX: tileX, tileY: tileY, tileWidth: tileWidth, tileHeight: tileHeight)
        default:
            throw RFBError.malformedMessage("unsupported ZRLE subencoding \(subencoding)")
        }
    }

    private func readPalette(reader: inout RFBByteReader, count: Int) throws -> [Data] {
        var palette: [Data] = []
        for _ in 0..<count {
            palette.append(try reader.readData(count: 3))
        }
        return palette
    }

    private func decodePackedPalette(reader: inout RFBByteReader, palette: [Data], output: inout Data, rectWidth: Int, tileX: Int, tileY: Int, tileWidth: Int, tileHeight: Int) throws {
        guard !palette.isEmpty else { throw RFBError.malformedMessage("ZRLE palette is empty") }
        let bitsPerPixel = palette.count <= 2 ? 1 : (palette.count <= 4 ? 2 : 4)
        let rowBytes = (tileWidth * bitsPerPixel + 7) / 8
        for row in 0..<tileHeight {
            let rowData = try reader.readData(count: rowBytes)
            var pixel = 0
            for byte in rowData {
                var shift = 8 - bitsPerPixel
                while shift >= 0, pixel < tileWidth {
                    let index = Int((byte >> UInt8(shift)) & UInt8((1 << bitsPerPixel) - 1))
                    guard index < palette.count else { throw RFBError.malformedMessage("ZRLE palette index out of range") }
                    writePixel(palette[index], output: &output, rectWidth: rectWidth, x: tileX + pixel, y: tileY + row)
                    pixel += 1
                    shift -= bitsPerPixel
                }
            }
        }
    }

    private func decodePlainRLE(reader: inout RFBByteReader, output: inout Data, rectWidth: Int, tileX: Int, tileY: Int, tileWidth: Int, tileHeight: Int) throws {
        var pixel = 0
        let total = tileWidth * tileHeight
        while pixel < total {
            let color = try reader.readData(count: 3)
            let runLength = try readRunLength(reader: &reader)
            for _ in 0..<runLength where pixel < total {
                writePixel(color, output: &output, rectWidth: rectWidth, x: tileX + pixel % tileWidth, y: tileY + pixel / tileWidth)
                pixel += 1
            }
        }
    }

    private func decodePaletteRLE(reader: inout RFBByteReader, palette: [Data], output: inout Data, rectWidth: Int, tileX: Int, tileY: Int, tileWidth: Int, tileHeight: Int) throws {
        guard !palette.isEmpty else { throw RFBError.malformedMessage("ZRLE palette is empty") }
        var pixel = 0
        let total = tileWidth * tileHeight
        while pixel < total {
            let indexByte = try reader.readUInt8()
            let index = Int(indexByte & 0x7f)
            guard index < palette.count else { throw RFBError.malformedMessage("ZRLE palette index out of range") }
            let runLength = (indexByte & 0x80) == 0 ? 1 : try readRunLength(reader: &reader)
            for _ in 0..<runLength where pixel < total {
                writePixel(palette[index], output: &output, rectWidth: rectWidth, x: tileX + pixel % tileWidth, y: tileY + pixel / tileWidth)
                pixel += 1
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

    private func writeTile(_ bytes: Data, output: inout Data, rectWidth: Int, tileX: Int, tileY: Int, tileWidth: Int, tileHeight: Int) {
        for row in 0..<tileHeight {
            let sourceOffset = row * tileWidth * 3
            let destinationOffset = ((tileY + row) * rectWidth + tileX) * 3
            output.replaceSubrange(destinationOffset..<(destinationOffset + tileWidth * 3), with: bytes[sourceOffset..<(sourceOffset + tileWidth * 3)])
        }
    }

    private func writeSolid(_ color: Data, output: inout Data, rectWidth: Int, tileX: Int, tileY: Int, tileWidth: Int, tileHeight: Int) {
        for row in 0..<tileHeight {
            for column in 0..<tileWidth {
                writePixel(color, output: &output, rectWidth: rectWidth, x: tileX + column, y: tileY + row)
            }
        }
    }

    private func writePixel(_ color: Data, output: inout Data, rectWidth: Int, x: Int, y: Int) {
        let offset = (y * rectWidth + x) * 3
        output.replaceSubrange(offset..<(offset + 3), with: color.prefix(3))
    }
}
