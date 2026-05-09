import NanoKVMCore
import SwiftUI
import UIKit

struct PointerCaptureView: UIViewRepresentable {
    let isEnabled: Bool
    let isScrollInverted: Bool
    let videoSize: CGSize?
    let onMouseReport: @MainActor (HIDMouseAbsoluteReport) -> Void

    func makeUIView(context: Context) -> PointerCaptureUIView {
        let view = PointerCaptureUIView()
        view.onMouseReport = onMouseReport
        view.isCaptureEnabled = isEnabled
        view.isScrollInverted = isScrollInverted
        view.videoSize = videoSize
        return view
    }

    func updateUIView(_ uiView: PointerCaptureUIView, context: Context) {
        uiView.onMouseReport = onMouseReport
        uiView.isCaptureEnabled = isEnabled
        uiView.isScrollInverted = isScrollInverted
        uiView.videoSize = videoSize
    }
}

final class PointerCaptureUIView: UIView {
    var isCaptureEnabled = false {
        didSet {
            if !isCaptureEnabled {
                releaseActiveDragIfNeeded()
            }
        }
    }
    var isScrollInverted = true
    var videoSize: CGSize?
    var onMouseReport: (@MainActor (HIDMouseAbsoluteReport) -> Void)?

    private let mouseReportBuilder = HIDMouseAbsoluteReportBuilder()
    private var scrollAccumulator = MouseScrollAccumulator()
    private var activeDragButtonNumber: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedScrollTypesMask = [.continuous, .discrete]
        addGestureRecognizer(pan)

        let primaryTap = UITapGestureRecognizer(target: self, action: #selector(handlePrimaryTap(_:)))
        primaryTap.buttonMaskRequired = .primary
        addGestureRecognizer(primaryTap)

        let secondaryTap = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryTap(_:)))
        secondaryTap.buttonMaskRequired = .secondary
        addGestureRecognizer(secondaryTap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard isCaptureEnabled else { return }
        let point = absolutePoint(for: recognizer.location(in: self))
        emit(mouseReportBuilder.move(x: point.x, y: point.y))
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard isCaptureEnabled else {
            releaseActiveDragIfNeeded()
            return
        }
        let location = recognizer.location(in: self)
        let point = absolutePoint(for: location)
        let dragButtonNumber = activeDragButtonNumber
            ?? PointerDragButtonResolver.buttonNumber(
                buttonMask: recognizer.buttonMask,
                touchCount: recognizer.numberOfTouches
            )

        switch recognizer.state {
        case .began:
            if let dragButtonNumber {
                activeDragButtonNumber = dragButtonNumber
                emit(mouseReportBuilder.buttonDown(buttonNumber: dragButtonNumber, x: point.x, y: point.y))
            } else {
                emit(mouseReportBuilder.move(x: point.x, y: point.y))
            }
        case .changed:
            if activeDragButtonNumber == nil, let dragButtonNumber {
                activeDragButtonNumber = dragButtonNumber
                emit(mouseReportBuilder.buttonDown(buttonNumber: dragButtonNumber, x: point.x, y: point.y))
            }
            emit(mouseReportBuilder.move(x: point.x, y: point.y))
        case .ended, .cancelled, .failed:
            if let activeDragButtonNumber {
                emit(mouseReportBuilder.buttonUp(buttonNumber: activeDragButtonNumber, x: point.x, y: point.y))
                self.activeDragButtonNumber = nil
            } else {
                emit(mouseReportBuilder.move(x: point.x, y: point.y))
            }
        default:
            break
        }

        guard activeDragButtonNumber == nil, dragButtonNumber == nil else {
            recognizer.setTranslation(.zero, in: self)
            return
        }

        // Trackpad scroll input reports `numberOfTouches == 0`; two-or-more direct
        // touches are routed to wheel scrolling. One-finger pans move or drag the pointer.
        guard PointerScrollResolver.shouldEmitWheel(touchCount: recognizer.numberOfTouches) else {
            recognizer.setTranslation(.zero, in: self)
            return
        }
        // `translation(in:)` is cumulative since the gesture began (or last reset), and
        // `MouseScrollAccumulator` adds its argument to its own running total. Reset every
        // callback so each call contributes only the delta since the previous one.
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        if let wheelDelta = scrollAccumulator.notches(
            for: translation.y,
            isInverted: isScrollInverted
        ) {
            emit(mouseReportBuilder.wheel(wheelDelta, x: point.x, y: point.y))
        }
    }

    @objc private func handlePrimaryTap(_ recognizer: UITapGestureRecognizer) {
        emitClick(buttonNumber: 0, at: recognizer.location(in: self))
    }

    @objc private func handleSecondaryTap(_ recognizer: UITapGestureRecognizer) {
        emitClick(buttonNumber: 1, at: recognizer.location(in: self))
    }

    private func emitClick(buttonNumber: Int, at location: CGPoint) {
        guard isCaptureEnabled else { return }
        let point = absolutePoint(for: location)
        emit(mouseReportBuilder.buttonDown(buttonNumber: buttonNumber, x: point.x, y: point.y))
        emit(mouseReportBuilder.buttonUp(buttonNumber: buttonNumber, x: point.x, y: point.y))
    }

    private func releaseActiveDragIfNeeded() {
        guard activeDragButtonNumber != nil else { return }
        activeDragButtonNumber = nil
        emit(mouseReportBuilder.reset())
    }

    private func emit(_ report: HIDMouseAbsoluteReport) {
        guard let onMouseReport else { return }
        Task { @MainActor in
            onMouseReport(report)
        }
    }

    private func absolutePoint(for point: CGPoint) -> (x: UInt16, y: UInt16) {
        MouseCoordinateMapper.absolutePoint(clientPoint: point, bounds: bounds, videoSize: videoSize)
    }
}

enum PointerDragButtonResolver {
    static func buttonNumber(buttonMask: UIEvent.ButtonMask, touchCount: Int) -> Int? {
        if buttonMask.contains(.primary) {
            return 0
        }
        if buttonMask.contains(.secondary) {
            return 1
        }
        if touchCount == 1 {
            return 0
        }
        return nil
    }
}

enum PointerScrollResolver {
    static func shouldEmitWheel(touchCount: Int) -> Bool {
        touchCount == 0 || touchCount >= 2
    }
}
