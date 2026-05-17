import XCTest
@testable import KVMCore

final class TripleEscapeDetectorTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func test_triggersOnThirdRapidPress() {
        var detector = TripleEscapeDetector()
        XCTAssertFalse(detector.register(at: base))
        XCTAssertFalse(detector.register(at: base.addingTimeInterval(0.4)))
        XCTAssertTrue(detector.register(at: base.addingTimeInterval(0.8)))
    }

    func test_doesNotTriggerWhenSpacedBeyondWindow() {
        var detector = TripleEscapeDetector()
        XCTAssertFalse(detector.register(at: base))
        XCTAssertFalse(detector.register(at: base.addingTimeInterval(1.0)))
        XCTAssertFalse(detector.register(at: base.addingTimeInterval(2.0)))
    }

    func test_keepsTriggeringWhileWindowIsSatisfied() {
        var detector = TripleEscapeDetector()
        _ = detector.register(at: base)
        _ = detector.register(at: base.addingTimeInterval(0.3))
        XCTAssertTrue(detector.register(at: base.addingTimeInterval(0.6)))
        XCTAssertTrue(detector.register(at: base.addingTimeInterval(0.9)))
        XCTAssertTrue(detector.register(at: base.addingTimeInterval(1.2)))
    }

    func test_slidingWindowDropsStaleEntries() {
        var detector = TripleEscapeDetector()
        _ = detector.register(at: base)
        _ = detector.register(at: base.addingTimeInterval(0.5))
        // Third press 1.6s after the first; the first falls out of the 1.5s window.
        XCTAssertFalse(detector.register(at: base.addingTimeInterval(1.6)))
        // A fresh fourth press lands inside the window with the previous two — refills to 3.
        XCTAssertTrue(detector.register(at: base.addingTimeInterval(1.7)))
    }

    func test_resetClearsBuffer() {
        var detector = TripleEscapeDetector()
        _ = detector.register(at: base)
        _ = detector.register(at: base.addingTimeInterval(0.2))
        detector.reset()
        XCTAssertFalse(detector.register(at: base.addingTimeInterval(0.4)))
        XCTAssertFalse(detector.register(at: base.addingTimeInterval(0.6)))
    }
}
