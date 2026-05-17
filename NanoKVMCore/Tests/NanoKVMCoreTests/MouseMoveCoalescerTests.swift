import XCTest
@testable import NanoKVMCore

final class MouseMoveCoalescerTests: XCTestCase {
    func test_collapsesQueuedMovesToLatestReport() async throws {
        let recorder = MouseReportRecorder(blockFirstSend: true)
        let coalescer = MouseMoveCoalescer { report in
            await recorder.send(report)
        }

        let first = HIDMouseAbsoluteReport(x: 10, y: 10)
        let stale = HIDMouseAbsoluteReport(x: 20, y: 20)
        let latest = HIDMouseAbsoluteReport(x: 30, y: 30)

        await coalescer.enqueue(first)
        try await recorder.waitForCount(1)
        await coalescer.enqueue(stale)
        await coalescer.enqueue(latest)

        await recorder.unblock()
        try await recorder.waitForCount(2)

        let reports = await recorder.reports
        XCTAssertEqual(reports, [first, latest])
    }

    func test_buttonReportsBypassPendingMoveAndPreserveOrder() async throws {
        let recorder = MouseReportRecorder(blockFirstSend: true)
        let coalescer = MouseMoveCoalescer { report in
            await recorder.send(report)
        }

        let first = HIDMouseAbsoluteReport(x: 10, y: 10)
        let staleMove = HIDMouseAbsoluteReport(x: 20, y: 20)
        let buttonDown = HIDMouseAbsoluteReport(buttons: 0x01, x: 30, y: 30)
        let buttonUp = HIDMouseAbsoluteReport(x: 30, y: 30)
        let latestMove = HIDMouseAbsoluteReport(x: 40, y: 40)

        await coalescer.enqueue(first)
        try await recorder.waitForCount(1)
        await coalescer.enqueue(staleMove)
        await coalescer.enqueue(buttonDown)
        await coalescer.enqueue(buttonUp)
        await coalescer.enqueue(latestMove)

        await recorder.unblock()
        try await recorder.waitForCount(4)

        let reports = await recorder.reports
        XCTAssertEqual(reports, [first, buttonDown, buttonUp, latestMove])
    }
}

private actor MouseReportRecorder {
    private(set) var reports: [HIDMouseAbsoluteReport] = []
    private var blockFirstSend: Bool
    private var continuation: CheckedContinuation<Void, Never>?

    init(blockFirstSend: Bool) {
        self.blockFirstSend = blockFirstSend
    }

    func send(_ report: HIDMouseAbsoluteReport) async {
        reports.append(report)
        guard blockFirstSend else { return }
        blockFirstSend = false
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func unblock() {
        continuation?.resume()
        continuation = nil
    }

    func waitForCount(_ count: Int) async throws {
        for _ in 0..<100 {
            if reports.count >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(count) mouse reports; saw \(reports.count).")
    }
}
