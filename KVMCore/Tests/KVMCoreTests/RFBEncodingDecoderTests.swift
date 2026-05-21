import XCTest
import zlib
@testable import KVMCore

final class RFBEncodingDecoderTests: XCTestCase {
    func test_zrleRawTileAppliesBGRPixels() throws {
        let framebuffer = RFBFramebuffer()
        try framebuffer.resize(width: 2, height: 1)
        let decoder = try RFBZRLEDecoder()
        let rect = RFBRectangle(x: 0, y: 0, width: 2, height: 1, encoding: RFBEncoding.zrle.rawValue)

        let tile = Data([
            0x00,
            0x01, 0x02, 0x03,
            0x04, 0x05, 0x06,
        ])
        try decoder.apply(rect: rect, compressedData: try zlibCompress(tile), to: framebuffer)

        XCTAssertEqual(
            try framebuffer.pixelBytes(),
            Data([0x01, 0x02, 0x03, 0, 0x04, 0x05, 0x06, 0])
        )
    }

    func test_zrleSolidTileAppliesColorAcrossTile() throws {
        let framebuffer = RFBFramebuffer()
        try framebuffer.resize(width: 2, height: 2)
        let decoder = try RFBZRLEDecoder()
        let rect = RFBRectangle(x: 0, y: 0, width: 2, height: 2, encoding: RFBEncoding.zrle.rawValue)

        let tile = Data([0x01, 0x10, 0x20, 0x30])
        try decoder.apply(rect: rect, compressedData: try zlibCompress(tile), to: framebuffer)

        XCTAssertEqual(
            try framebuffer.pixelBytes(),
            Data([
                0x10, 0x20, 0x30, 0, 0x10, 0x20, 0x30, 0,
                0x10, 0x20, 0x30, 0, 0x10, 0x20, 0x30, 0,
            ])
        )
    }

    func test_zrlePaletteRLETileAppliesRuns() throws {
        let framebuffer = RFBFramebuffer()
        try framebuffer.resize(width: 4, height: 1)
        let decoder = try RFBZRLEDecoder()
        let rect = RFBRectangle(x: 0, y: 0, width: 4, height: 1, encoding: RFBEncoding.zrle.rawValue)

        let tile = Data([
            0x82,
            0x01, 0x02, 0x03,
            0x10, 0x20, 0x30,
            0x81, 0x03,
        ])
        try decoder.apply(rect: rect, compressedData: try zlibCompress(tile), to: framebuffer)

        XCTAssertEqual(
            try framebuffer.pixelBytes(),
            Data([
                0x10, 0x20, 0x30, 0,
                0x10, 0x20, 0x30, 0,
                0x10, 0x20, 0x30, 0,
                0x10, 0x20, 0x30, 0,
            ])
        )
    }

    func test_bigUIntModExpUsesBigEndianInputs() {
        let result = RFBBigUInt.modExp(
            base: RFBBigUInt(5),
            exponent: RFBBigUInt(117),
            modulus: RFBBigUInt(19)
        )

        XCTAssertEqual(result.bigEndianData(paddedTo: 1), Data([1]))
    }

    private func zlibCompress(_ data: Data) throws -> Data {
        var stream = z_stream()
        XCTAssertEqual(deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
        defer { deflateEnd(&stream) }

        var input = data
        var output = Data()
        try input.withUnsafeMutableBytes { inputBuffer in
            stream.next_in = inputBuffer.baseAddress?.assumingMemoryBound(to: Bytef.self)
            stream.avail_in = uInt(data.count)
            repeat {
                var chunk = [UInt8](repeating: 0, count: 256)
                let status = chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return deflate(&stream, Z_FINISH)
                }
                let produced = chunk.count - Int(stream.avail_out)
                output.append(contentsOf: chunk.prefix(produced))
                guard status == Z_OK || status == Z_STREAM_END else {
                    throw RFBError.malformedMessage("deflate failed")
                }
                if status == Z_STREAM_END { break }
            } while true
        }
        return output
    }
}
