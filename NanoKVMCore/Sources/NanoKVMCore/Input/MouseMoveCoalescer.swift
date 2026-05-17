import Foundation

public actor MouseMoveCoalescer {
    private let send: @Sendable (HIDMouseAbsoluteReport) async -> Void
    private var immediateReports: [HIDMouseAbsoluteReport] = []
    private var pendingMove: HIDMouseAbsoluteReport?
    private var isSending = false
    private var lastButtons: UInt8 = 0

    public init(send: @escaping @Sendable (HIDMouseAbsoluteReport) async -> Void) {
        self.send = send
    }

    public func enqueue(_ report: HIDMouseAbsoluteReport) {
        let isMoveOnly = report.wheel == 0 && report.buttons == lastButtons
        lastButtons = report.buttons

        if isMoveOnly {
            pendingMove = report
        } else {
            pendingMove = nil
            immediateReports.append(report)
        }

        drainIfNeeded()
    }

    public func cancel() {
        immediateReports.removeAll()
        pendingMove = nil
    }

    private func drainIfNeeded() {
        guard !isSending else { return }

        let nextReport: HIDMouseAbsoluteReport?
        if !immediateReports.isEmpty {
            nextReport = immediateReports.removeFirst()
        } else {
            nextReport = pendingMove
            pendingMove = nil
        }

        guard let nextReport else { return }
        isSending = true
        Task.detached(priority: .userInitiated) { [send, nextReport] in
            await send(nextReport)
            await self.sendCompleted()
        }
    }

    private func sendCompleted() {
        isSending = false
        drainIfNeeded()
    }
}
