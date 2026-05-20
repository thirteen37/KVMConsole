import XCTest
@testable import KVMCore

final class H264FrameContinuityGateTests: XCTestCase {
    func test_contiguousFramesDoNotResetOrSkip() {
        var gate = H264FrameContinuityGate()

        XCTAssertEqual(inspect(&gate, sequenceNumber: 0, isKeyFrame: true), .decode)
        XCTAssertEqual(inspect(&gate, sequenceNumber: 1, isKeyFrame: false), .decode)
        XCTAssertEqual(inspect(&gate, sequenceNumber: 2, isKeyFrame: false), .decode)
    }

    func test_gapBeforeKeyframeResetsAndDecodesKeyframe() {
        var gate = H264FrameContinuityGate()

        _ = inspect(&gate, sequenceNumber: 0, isKeyFrame: true)

        XCTAssertEqual(inspect(&gate, sequenceNumber: 2, isKeyFrame: true), .resetAndDecodeKeyframe)
        XCTAssertEqual(inspect(&gate, sequenceNumber: 3, isKeyFrame: false), .decode)
    }

    func test_gapBeforeDeltaFrameDecodesThroughWithoutResetting() {
        var gate = H264FrameContinuityGate()

        _ = inspect(&gate, sequenceNumber: 0, isKeyFrame: true)

        XCTAssertEqual(inspect(&gate, sequenceNumber: 2, isKeyFrame: false), .decodeThroughDiscontinuity)
        XCTAssertEqual(inspect(&gate, sequenceNumber: 3, isKeyFrame: false), .decode)
    }

    func test_resetClearsSequenceTracking() {
        var gate = H264FrameContinuityGate()

        _ = inspect(&gate, sequenceNumber: 10, isKeyFrame: true)
        gate.reset()

        XCTAssertEqual(inspect(&gate, sequenceNumber: 0, isKeyFrame: false), .decode)
    }

    private func inspect(
        _ gate: inout H264FrameContinuityGate,
        sequenceNumber: UInt64,
        isKeyFrame: Bool
    ) -> H264FrameContinuityAction {
        gate.inspect(frame(sequenceNumber: sequenceNumber, isKeyFrame: isKeyFrame), isKeyFrame: isKeyFrame)
    }

    private func frame(sequenceNumber: UInt64, isKeyFrame: Bool) -> H264StreamFrame {
        H264StreamFrame(
            isKeyFrame: isKeyFrame,
            timestampMicros: sequenceNumber,
            payload: Data([0x00, 0x00, 0x01, isKeyFrame ? 0x65 : 0x41]),
            sequenceNumber: sequenceNumber
        )
    }
}
