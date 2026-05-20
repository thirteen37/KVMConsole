import CoreGraphics
import Foundation
import ImageIO

public final class RFBTightDecoder: @unchecked Sendable {
    private var streams: [RFBZlibInflater]

    public init() throws {
        self.streams = try (0..<4).map { _ in try RFBZlibInflater() }
    }

    public func apply(rect: RFBRectangle, payload: Data, to framebuffer: RFBFramebuffer) throws {
        var reader = RFBByteReader(payload)
        let control = try reader.readUInt8()
        for streamIndex in 0..<4 where (control & UInt8(1 << streamIndex)) != 0 {
            try streams[streamIndex].reset()
        }

        let compressionType = control >> 4
        switch compressionType {
        case 0x08:
            let rgb = try reader.readData(count: 3)
            let bytes = Array(rgb)
            try framebuffer.fill(rect: rect, bgra: (bytes[2], bytes[1], bytes[0], 0))
        case 0x09:
            let length = try readCompactLength(reader: &reader)
            let jpegData = try reader.readData(count: length)
            let rgb = try decodeJPEG(jpegData, width: Int(rect.width), height: Int(rect.height))
            try framebuffer.applyRGB(rect: rect, bytes: rgb)
        case 0x00...0x07:
            try applyBasic(control: control, rect: rect, reader: &reader, framebuffer: framebuffer)
        default:
            throw RFBError.malformedMessage("unsupported Tight compression control \(control)")
        }
    }

    private func applyBasic(
        control: UInt8,
        rect: RFBRectangle,
        reader: inout RFBByteReader,
        framebuffer: RFBFramebuffer
    ) throws {
        let width = Int(rect.width)
        let height = Int(rect.height)
        let streamID = Int((control >> 4) & 0x03)
        let filter = (control & 0x40) != 0 ? try reader.readUInt8() : 0

        switch filter {
        case 0:
            let expected = width * height * 3
            let data = try readBasicData(reader: &reader, streamID: streamID, expectedByteCount: expected)
            try framebuffer.applyRGB(rect: rect, bytes: data)
        case 1:
            let paletteSize = Int(try reader.readUInt8()) + 1
            var palette: [Data] = []
            for _ in 0..<paletteSize {
                palette.append(try reader.readData(count: 3))
            }
            let indexedSize = paletteSize == 2 ? ((width + 7) / 8) * height : width * height
            let indexes = try readBasicData(reader: &reader, streamID: streamID, expectedByteCount: indexedSize)
            let rgb = try expandPalette(indexes: indexes, palette: palette, width: width, height: height)
            try framebuffer.applyRGB(rect: rect, bytes: rgb)
        case 2:
            throw RFBError.unsupportedEncoding(RFBEncoding.tight.rawValue)
        default:
            throw RFBError.malformedMessage("unsupported Tight filter \(filter)")
        }
    }

    private func readBasicData(reader: inout RFBByteReader, streamID: Int, expectedByteCount: Int) throws -> Data {
        if expectedByteCount < 12 {
            return try reader.readData(count: expectedByteCount)
        }
        let length = try readCompactLength(reader: &reader)
        let compressed = try reader.readData(count: length)
        return try streams[streamID].inflate(compressed, expectedByteCount: expectedByteCount)
    }

    private func expandPalette(indexes: Data, palette: [Data], width: Int, height: Int) throws -> Data {
        guard !palette.isEmpty else { throw RFBError.malformedMessage("Tight palette is empty") }
        var rgb = Data(count: width * height * 3)
        rgb.withUnsafeMutableBytes { destination in
            guard let base = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            if palette.count == 2 {
                let rowBytes = (width + 7) / 8
                for y in 0..<height {
                    for xByte in 0..<rowBytes {
                        let byte = indexes[y * rowBytes + xByte]
                        for bit in 0..<8 {
                            let x = xByte * 8 + bit
                            guard x < width else { break }
                            let index = Int((byte >> UInt8(7 - bit)) & 1)
                            writeRGB(palette[index], to: base, pixelIndex: y * width + x)
                        }
                    }
                }
            } else {
                for pixelIndex in 0..<(width * height) {
                    let index = Int(indexes[pixelIndex])
                    guard index < palette.count else { continue }
                    writeRGB(palette[index], to: base, pixelIndex: pixelIndex)
                }
            }
        }
        return rgb
    }

    private func writeRGB(_ color: Data, to base: UnsafeMutablePointer<UInt8>, pixelIndex: Int) {
        let colorBytes = Array(color.prefix(3))
        base[pixelIndex * 3] = colorBytes[0]
        base[pixelIndex * 3 + 1] = colorBytes[1]
        base[pixelIndex * 3 + 2] = colorBytes[2]
    }

    private func decodeJPEG(_ data: Data, width: Int, height: Int) throws -> Data {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw RFBError.malformedMessage("failed to decode Tight JPEG")
        }

        var bgra = Data(count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        bgra.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        var rgb = Data(count: width * height * 3)
        rgb.withUnsafeMutableBytes { destination in
            bgra.withUnsafeBytes { source in
                guard let destinationBase = destination.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let sourceBase = source.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return }
                for index in 0..<(width * height) {
                    destinationBase[index * 3] = sourceBase[index * 4 + 2]
                    destinationBase[index * 3 + 1] = sourceBase[index * 4 + 1]
                    destinationBase[index * 3 + 2] = sourceBase[index * 4]
                }
            }
        }
        return rgb
    }

    private func readCompactLength(reader: inout RFBByteReader) throws -> Int {
        let byte0 = Int(try reader.readUInt8())
        var length = byte0 & 0x7f
        if (byte0 & 0x80) != 0 {
            let byte1 = Int(try reader.readUInt8())
            length |= (byte1 & 0x7f) << 7
            if (byte1 & 0x80) != 0 {
                let byte2 = Int(try reader.readUInt8())
                length |= byte2 << 14
            }
        }
        return length
    }
}
