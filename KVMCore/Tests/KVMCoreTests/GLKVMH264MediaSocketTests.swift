import XCTest
@testable import KVMCore

final class GLKVMH264MediaSocketTests: XCTestCase {
    func test_parseDirectKeyFrame() throws {
        let frame = try XCTUnwrap(GLKVMDirectH264FrameParser.parse(
            Data([0x01, 0x01, 0x00, 0x00, 0x00, 0x01, 0x65]),
            timestampMicros: 123
        ))

        XCTAssertTrue(frame.isKeyFrame)
        XCTAssertEqual(frame.timestampMicros, 123)
        XCTAssertEqual(frame.payload, Data([0x00, 0x00, 0x00, 0x01, 0x65]))
    }

    func test_parseDirectDeltaFrame() throws {
        let frame = try XCTUnwrap(GLKVMDirectH264FrameParser.parse(
            Data([0x01, 0x00, 0x00, 0x00, 0x01, 0x41]),
            timestampMicros: 456
        ))

        XCTAssertFalse(frame.isKeyFrame)
        XCTAssertEqual(frame.timestampMicros, 456)
        XCTAssertEqual(frame.payload, Data([0x00, 0x00, 0x01, 0x41]))
    }

    func test_parseHeartbeatReturnsNil() throws {
        let frame = try GLKVMDirectH264FrameParser.parse(Data([0xff]), timestampMicros: 1)

        XCTAssertNil(frame)
    }

    func test_parseRejectsEmptyPayload() {
        XCTAssertThrowsError(try GLKVMDirectH264FrameParser.parse(Data([0x01, 0x01]), timestampMicros: 1)) { error in
            XCTAssertEqual(error as? GLKVMH264MediaError, .emptyPayload)
        }
    }
}
