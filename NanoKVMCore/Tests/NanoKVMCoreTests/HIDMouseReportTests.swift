import XCTest
@testable import NanoKVMCore

final class HIDMouseReportTests: XCTestCase {
    func test_reportBuildsNanoKVMAbsoluteMouseMessage() {
        let report = HIDMouseAbsoluteReport(buttons: 0x03, x: 0x1234, y: 0xabcd, wheel: -1)

        XCTAssertEqual(
            report.nanoKVMMessageData,
            Data([0x02, 0x03, 0x34, 0x12, 0xcd, 0xab, 0xff])
        )
    }

    func test_builderTracksButtonsUsingNanoKVMBits() {
        let builder = HIDMouseAbsoluteReportBuilder()

        XCTAssertEqual(
            builder.buttonDown(buttonNumber: 0, x: 10, y: 20),
            HIDMouseAbsoluteReport(buttons: 0x01, x: 10, y: 20)
        )
        XCTAssertEqual(
            builder.buttonDown(buttonNumber: 1, x: 11, y: 21),
            HIDMouseAbsoluteReport(buttons: 0x03, x: 11, y: 21)
        )
        XCTAssertEqual(
            builder.buttonDown(buttonNumber: 2, x: 12, y: 22),
            HIDMouseAbsoluteReport(buttons: 0x07, x: 12, y: 22)
        )
        XCTAssertEqual(
            builder.buttonUp(buttonNumber: 0, x: 13, y: 23),
            HIDMouseAbsoluteReport(buttons: 0x06, x: 13, y: 23)
        )
        XCTAssertEqual(builder.reset(), HIDMouseAbsoluteReport(buttons: 0, x: 13, y: 23))
    }

    func test_builderUsesSignedWheelByte() {
        let builder = HIDMouseAbsoluteReportBuilder()

        XCTAssertEqual(
            builder.wheel(-1, x: 100, y: 200).nanoKVMMessageData,
            Data([0x02, 0x00, 0x64, 0x00, 0xc8, 0x00, 0xff])
        )
    }

    func test_scrollAccumulatorSwallowsSubThresholdDeltas() {
        var accumulator = MouseScrollAccumulator()
        XCTAssertNil(accumulator.notches(for: 4, isInverted: false))
        XCTAssertNil(accumulator.notches(for: 4, isInverted: false))
        XCTAssertNil(accumulator.notches(for: 4, isInverted: false))
    }

    func test_scrollAccumulatorEmitsOneNotchWhenThresholdReached() {
        var accumulator = MouseScrollAccumulator()
        // Three increments of 6 sum to 18, crossing the 16-point threshold.
        XCTAssertNil(accumulator.notches(for: 6, isInverted: false))
        XCTAssertNil(accumulator.notches(for: 6, isInverted: false))
        XCTAssertEqual(accumulator.notches(for: 6, isInverted: false), 1)
    }

    func test_scrollAccumulatorBatchesMultipleNotches() {
        var accumulator = MouseScrollAccumulator()
        XCTAssertEqual(accumulator.notches(for: 64, isInverted: false), 4)
        XCTAssertEqual(accumulator.notches(for: -64, isInverted: false), -4)
    }

    func test_scrollAccumulatorRespectsInversion() {
        var accumulator = MouseScrollAccumulator()
        XCTAssertEqual(accumulator.notches(for: 32, isInverted: true), -2)
    }

    func test_scrollAccumulatorIgnoresZeroDelta() {
        var accumulator = MouseScrollAccumulator()
        XCTAssertNil(accumulator.notches(for: 0, isInverted: false))
    }

    func test_scrollAccumulatorReversesAcrossDirectionChange() {
        var accumulator = MouseScrollAccumulator()
        // Build up a partial positive accumulation, then a negative delta cancels and overshoots.
        XCTAssertNil(accumulator.notches(for: 10, isInverted: false))
        XCTAssertEqual(accumulator.notches(for: -32, isInverted: false), -1)
    }

    func test_coordinateMapperUsesFullBoundsWithoutVideoSize() {
        let point = MouseCoordinateMapper.absolutePoint(
            clientPoint: CGPoint(x: 50, y: 50),
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            videoSize: nil
        )

        XCTAssertEqual(point.x, 16_384)
        XCTAssertEqual(point.y, 16_384)
    }

    func test_coordinateMapperAccountsForLetterboxing() {
        let center = MouseCoordinateMapper.absolutePoint(
            clientPoint: CGPoint(x: 50, y: 50),
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            videoSize: CGSize(width: 16, height: 9)
        )

        let topLetterbox = MouseCoordinateMapper.absolutePoint(
            clientPoint: CGPoint(x: 50, y: 0),
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            videoSize: CGSize(width: 16, height: 9)
        )

        XCTAssertEqual(center.x, 16_384)
        XCTAssertEqual(center.y, 16_384)
        XCTAssertEqual(topLetterbox.x, 16_384)
        XCTAssertEqual(topLetterbox.y, 1)
    }

    func test_coordinateMapperClampsOutsideMediaRect() {
        let point = MouseCoordinateMapper.absolutePoint(
            clientPoint: CGPoint(x: 200, y: 200),
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            videoSize: CGSize(width: 4, height: 3)
        )

        XCTAssertEqual(point.x, 32_768)
        XCTAssertEqual(point.y, 32_768)
    }
}
