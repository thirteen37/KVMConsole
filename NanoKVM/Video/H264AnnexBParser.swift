import Foundation

struct H264NALUnit: Equatable, Sendable {
    let type: UInt8
    let data: Data

    var isSPS: Bool { type == 7 }
    var isPPS: Bool { type == 8 }
}

enum H264AnnexBParser {
    static func parseNALUnits(from data: Data) -> [H264NALUnit] {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return [] }

        var starts: [(startCodeOffset: Int, payloadOffset: Int)] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    starts.append((index, index + 3))
                    index += 3
                    continue
                }
                if index + 3 < bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    starts.append((index, index + 4))
                    index += 4
                    continue
                }
            }
            index += 1
        }

        guard !starts.isEmpty else { return [] }

        var units: [H264NALUnit] = []
        for unitIndex in starts.indices {
            let payloadStart = starts[unitIndex].payloadOffset
            var payloadEnd = unitIndex + 1 < starts.count ? starts[unitIndex + 1].startCodeOffset : bytes.count
            while payloadEnd > payloadStart, bytes[payloadEnd - 1] == 0 {
                payloadEnd -= 1
            }
            guard payloadEnd > payloadStart else { continue }

            let payload = Data(bytes[payloadStart..<payloadEnd])
            guard let first = payload.first else { continue }
            units.append(H264NALUnit(type: first & 0x1F, data: payload))
        }

        return units
    }
}
