import XCTest
@testable import KVMCore

final class H264StreamFrameParserTests: XCTestCase {
    func test_parseKeyFrame() throws {
        let frame = try H264StreamFrameParser.parse(frameData(key: true, timestamp: 1_234_567, payload: [0, 0, 0, 1, 0x65]))

        XCTAssertTrue(frame.isKeyFrame)
        XCTAssertEqual(frame.timestampMicros, 1_234_567)
        XCTAssertEqual(frame.payload, Data([0, 0, 0, 1, 0x65]))
    }

    func test_parseDeltaFrame() throws {
        let frame = try H264StreamFrameParser.parse(frameData(key: false, timestamp: 42, payload: [0, 0, 1, 0x41]))

        XCTAssertFalse(frame.isKeyFrame)
        XCTAssertEqual(frame.timestampMicros, 42)
        XCTAssertEqual(frame.payload, Data([0, 0, 1, 0x41]))
    }

    func test_parseTimestampAsLittleEndianUInt64() throws {
        let frame = try H264StreamFrameParser.parse(frameData(key: true, timestamp: 0x0102_0304_0506_0708, payload: [1]))

        XCTAssertEqual(frame.timestampMicros, 0x0102_0304_0506_0708)
    }

    func test_rejectsShortFrame() {
        XCTAssertThrowsError(try H264StreamFrameParser.parse(Data([1, 2, 3]))) { error in
            XCTAssertEqual(error as? H264StreamError, .frameTooShort)
        }
    }

    func test_rejectsEmptyPayload() {
        XCTAssertThrowsError(try H264StreamFrameParser.parse(frameData(key: true, timestamp: 1, payload: []))) { error in
            XCTAssertEqual(error as? H264StreamError, .emptyPayload)
        }
    }

    private func frameData(key: Bool, timestamp: UInt64, payload: [UInt8]) -> Data {
        var data = Data([key ? 1 : 0])
        var littleEndianTimestamp = timestamp.littleEndian
        withUnsafeBytes(of: &littleEndianTimestamp) { data.append(contentsOf: $0) }
        data.append(contentsOf: payload)
        return data
    }
}
