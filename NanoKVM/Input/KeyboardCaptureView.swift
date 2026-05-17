import AppKit
import NanoKVMCore
import SwiftUI

struct KeyboardCaptureView: NSViewRepresentable {
    let isKeyboardEnabled: Bool
    let isMouseEnabled: Bool
    let isScrollInverted: Bool
    let videoSize: CGSize?
    let zoom: ViewerZoomState
    let onKeyboardReport: @MainActor (HIDKeyboardReport) -> Void
    let onMouseReport: @MainActor (HIDMouseAbsoluteReport) -> Void

    func makeNSView(context: Context) -> CaptureNSView {
        let view = CaptureNSView()
        view.onKeyboardReport = onKeyboardReport
        view.onMouseReport = onMouseReport
        view.setKeyboardEnabled(isKeyboardEnabled)
        view.setMouseEnabled(isMouseEnabled)
        view.isScrollInverted = isScrollInverted
        view.videoSize = videoSize
        view.zoom = zoom
        return view
    }

    func updateNSView(_ nsView: CaptureNSView, context: Context) {
        nsView.onKeyboardReport = onKeyboardReport
        nsView.onMouseReport = onMouseReport
        nsView.setKeyboardEnabled(isKeyboardEnabled)
        nsView.setMouseEnabled(isMouseEnabled)
        nsView.isScrollInverted = isScrollInverted
        nsView.videoSize = videoSize
        nsView.zoom = zoom
    }
}

final class CaptureNSView: NSView {
    private(set) var isKeyboardEnabled = false
    private(set) var isMouseEnabled = false
    var isScrollInverted = true
    var videoSize: CGSize?
    var zoom: ViewerZoomState?
    var onKeyboardReport: (@MainActor (HIDKeyboardReport) -> Void)?
    var onMouseReport: (@MainActor (HIDMouseAbsoluteReport) -> Void)?
    private let keyboardReportBuilder = HIDKeyboardReportBuilder()
    private let mouseReportBuilder = HIDMouseAbsoluteReportBuilder()
    private var scrollAccumulator = MouseScrollAccumulator()
    private var isMouseInside = false
    private var isCursorHidden = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isKeyboardEnabled || isMouseEnabled {
            window?.makeFirstResponder(self)
        }
        if window == nil {
            setCursorHidden(false)
            isMouseInside = false
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for trackingArea in trackingAreas {
            removeTrackingArea(trackingArea)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self
        ))
    }

    func setKeyboardEnabled(_ enabled: Bool) {
        let wasEnabled = isKeyboardEnabled
        isKeyboardEnabled = enabled
        if enabled, !wasEnabled {
            requestFirstResponder()
        }
    }

    func setMouseEnabled(_ enabled: Bool) {
        let wasEnabled = isMouseEnabled
        isMouseEnabled = enabled
        updateCursorVisibility()
        if enabled, !wasEnabled {
            requestFirstResponder()
        }
    }

    private func requestFirstResponder() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        updateCursorVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        updateCursorVisibility()
    }

    private func updateCursorVisibility() {
        setCursorHidden(isMouseEnabled && isMouseInside)
    }

    private func setCursorHidden(_ shouldHide: Bool) {
        if shouldHide && !isCursorHidden {
            NSCursor.hide()
            isCursorHidden = true
        } else if !shouldHide && isCursorHidden {
            NSCursor.unhide()
            isCursorHidden = false
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard isMouseEnabled else { return }
        let point = absolutePoint(for: event)
        emit(mouseReportBuilder.buttonDown(buttonNumber: event.buttonNumber, x: point.x, y: point.y))
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard isMouseEnabled else { return }
        let point = absolutePoint(for: event)
        emit(mouseReportBuilder.buttonDown(buttonNumber: event.buttonNumber, x: point.x, y: point.y))
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard isMouseEnabled else { return }
        let point = absolutePoint(for: event)
        emit(mouseReportBuilder.buttonDown(buttonNumber: event.buttonNumber, x: point.x, y: point.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard isMouseEnabled else { return }
        let point = absolutePoint(for: event)
        emit(mouseReportBuilder.buttonUp(buttonNumber: event.buttonNumber, x: point.x, y: point.y))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard isMouseEnabled else { return }
        let point = absolutePoint(for: event)
        emit(mouseReportBuilder.buttonUp(buttonNumber: event.buttonNumber, x: point.x, y: point.y))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard isMouseEnabled else { return }
        let point = absolutePoint(for: event)
        emit(mouseReportBuilder.buttonUp(buttonNumber: event.buttonNumber, x: point.x, y: point.y))
    }

    override func mouseMoved(with event: NSEvent) {
        emitMove(for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        emitMove(for: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        emitMove(for: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        emitMove(for: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard
            isMouseEnabled,
            let wheelDelta = scrollAccumulator.notches(
                for: event.scrollingDeltaY,
                isInverted: isScrollInverted
            )
        else { return }
        let point = absolutePoint(for: event)
        emit(mouseReportBuilder.wheel(wheelDelta, x: point.x, y: point.y))
    }

    override func magnify(with event: NSEvent) {
        guard let zoom else {
            super.magnify(with: event)
            return
        }
        let factor = 1 + event.magnification
        guard factor > 0 else { return }
        let location = convert(event.locationInWindow, from: nil)
        let anchor = MouseCoordinateMapper.normalizedPoint(
            clientPoint: location,
            effectiveRect: effectiveRect()
        )
        zoom.applyPinch(factor: factor, anchorNormalized: anchor)
    }

    override func keyDown(with event: NSEvent) {
        guard isKeyboardEnabled, !event.isARepeat, let usage = HIDKeymap.usage(for: event.keyCode) else {
            return
        }
        emit(keyboardReportBuilder.keyDown(usage: usage))
    }

    override func keyUp(with event: NSEvent) {
        guard isKeyboardEnabled, let usage = HIDKeymap.usage(for: event.keyCode) else {
            return
        }
        emit(keyboardReportBuilder.keyUp(usage: usage))
    }

    override func flagsChanged(with event: NSEvent) {
        guard isKeyboardEnabled, let bit = HIDKeymap.modifierBit(for: event.keyCode) else {
            return
        }
        let isPressed = HIDKeymap.isModifierPressed(keyCode: event.keyCode, in: event.modifierFlags)
        emit(keyboardReportBuilder.modifierChanged(bit: bit, isPressed: isPressed))
    }

    override func resignFirstResponder() -> Bool {
        emit(keyboardReportBuilder.reset())
        emit(mouseReportBuilder.reset())
        return super.resignFirstResponder()
    }

    private func emit(_ report: HIDKeyboardReport) {
        guard let onKeyboardReport else { return }
        Task { @MainActor in
            onKeyboardReport(report)
        }
    }

    private func emit(_ report: HIDMouseAbsoluteReport) {
        guard isMouseEnabled, let onMouseReport else { return }
        Task { @MainActor in
            onMouseReport(report)
        }
    }

    private func emitMove(for event: NSEvent) {
        guard isMouseEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        let effective = effectiveRect()
        let normalized = MouseCoordinateMapper.normalizedPoint(clientPoint: point, effectiveRect: effective)
        let absolute = MouseCoordinateMapper.absolutePoint(clientPoint: point, effectiveRect: effective)
        emit(mouseReportBuilder.move(x: absolute.x, y: absolute.y))
        zoom?.cursorNormalized = normalized
        zoom?.ensureCursorVisible(cursorNormalized: normalized)
    }

    private func absolutePoint(for event: NSEvent) -> (x: UInt16, y: UInt16) {
        let point = convert(event.locationInWindow, from: nil)
        let effective = effectiveRect()
        let normalized = MouseCoordinateMapper.normalizedPoint(clientPoint: point, effectiveRect: effective)
        zoom?.cursorNormalized = normalized
        return MouseCoordinateMapper.absolutePoint(clientPoint: point, effectiveRect: effective)
    }

    private func effectiveRect() -> CGRect {
        let baseRect = MouseCoordinateMapper.aspectFitRect(for: videoSize, in: bounds)
        guard let zoom else { return baseRect }
        return zoom.effectiveVideoRect(in: bounds, baseRect: baseRect)
    }
}
