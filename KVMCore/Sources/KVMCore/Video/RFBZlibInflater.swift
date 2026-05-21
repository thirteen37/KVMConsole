import Foundation
import zlib

final class RFBZlibInflater: @unchecked Sendable {
    private var stream = z_stream()
    private var isInitialized = false

    init() throws {
        try reset()
    }

    deinit {
        if isInitialized {
            inflateEnd(&stream)
        }
    }

    func reset() throws {
        if isInitialized {
            inflateEnd(&stream)
        }
        stream = z_stream()
        let status = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw RFBError.malformedMessage("zlib inflate init failed: \(status)")
        }
        isInitialized = true
    }

    func inflate(_ data: Data, expectedByteCount: Int? = nil) throws -> Data {
        var output = Data()
        var input = data
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        try input.withUnsafeMutableBytes { inputBuffer in
            stream.next_in = inputBuffer.baseAddress?.assumingMemoryBound(to: Bytef.self)
            stream.avail_in = uInt(data.count)

            repeat {
                let status = chunk.withUnsafeMutableBufferPointer { chunkBuffer in
                    stream.next_out = chunkBuffer.baseAddress
                    stream.avail_out = uInt(chunkBuffer.count)
                    return zlib.inflate(&stream, Z_SYNC_FLUSH)
                }
                let produced = chunk.count - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: chunk.prefix(produced))
                }
                guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                    throw RFBError.malformedMessage("zlib inflate failed: \(status)")
                }
                if status == Z_STREAM_END {
                    try reset()
                    break
                }
                if produced == 0 && stream.avail_in == 0 {
                    break
                }
            } while stream.avail_in > 0 || (expectedByteCount.map { output.count < $0 } ?? false)
        }
        return output
    }
}
