import AppKit
import Foundation
import NanoKVMCore

@MainActor
final class FullscreenKeyCaptureCoordinator {
    private static let escapeKeyCode: UInt16 = 53
    private static let topEdgeRevealZone: CGFloat = 4
    private static let topEdgeHideZone: CGFloat = 60

    private let isCapturing: @MainActor () -> Bool
    private let onKeyboardReport: @MainActor (HIDKeyboardReport) -> Void
    private let onTripleEscape: @MainActor () -> Void
    private let onTopEdgeHover: @MainActor () -> Void
    private let onTopEdgeLeft: @MainActor () -> Void

    private let builder = HIDKeyboardReportBuilder()
    private var escapeDetector = TripleEscapeDetector()
    private weak var window: NSWindow?
    private var monitor: Any?
    private var savedPresentationOptions: NSApplication.PresentationOptions?
    private var savedAcceptsMouseMovedEvents: Bool?

    init(
        isCapturing: @escaping @MainActor () -> Bool,
        onKeyboardReport: @escaping @MainActor (HIDKeyboardReport) -> Void,
        onTripleEscape: @escaping @MainActor () -> Void,
        onTopEdgeHover: @escaping @MainActor () -> Void,
        onTopEdgeLeft: @escaping @MainActor () -> Void
    ) {
        self.isCapturing = isCapturing
        self.onKeyboardReport = onKeyboardReport
        self.onTripleEscape = onTripleEscape
        self.onTopEdgeHover = onTopEdgeHover
        self.onTopEdgeLeft = onTopEdgeLeft
    }

    func start(window: NSWindow) {
        guard monitor == nil else { return }
        self.window = window

        savedPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock, .disableProcessSwitching]

        savedAcceptsMouseMovedEvents = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged, .mouseMoved]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleEvent(event)
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil

        if let savedPresentationOptions {
            NSApp.presentationOptions = savedPresentationOptions
        }
        savedPresentationOptions = nil

        if let window, let savedAcceptsMouseMovedEvents {
            window.acceptsMouseMovedEvents = savedAcceptsMouseMovedEvents
        }
        savedAcceptsMouseMovedEvents = nil
        window = nil
        escapeDetector.reset()

        onKeyboardReport(builder.reset())
    }

    private func handleEvent(_ event: NSEvent) -> NSEvent? {
        guard let window, NSApp.keyWindow === window else { return event }

        if event.type == .mouseMoved {
            handleMouseMoved(event, in: window)
            return event
        }

        guard isCapturing() else { return event }

        if event.type == .keyDown, event.keyCode == Self.escapeKeyCode {
            if escapeDetector.register(at: Date()) {
                escapeDetector.reset()
                onTripleEscape()
            }
        }

        if let report = report(for: event) {
            onKeyboardReport(report)
        }
        return nil
    }

    private func handleMouseMoved(_ event: NSEvent, in window: NSWindow) {
        let topY = window.frame.height
        let distanceFromTop = topY - event.locationInWindow.y
        if distanceFromTop <= Self.topEdgeRevealZone {
            onTopEdgeHover()
        } else if distanceFromTop >= Self.topEdgeHideZone {
            onTopEdgeLeft()
        }
    }

    private func report(for event: NSEvent) -> HIDKeyboardReport? {
        switch event.type {
        case .keyDown:
            guard !event.isARepeat, let usage = HIDKeymap.usage(for: event.keyCode) else { return nil }
            return builder.keyDown(usage: usage)
        case .keyUp:
            guard let usage = HIDKeymap.usage(for: event.keyCode) else { return nil }
            return builder.keyUp(usage: usage)
        case .flagsChanged:
            guard let bit = HIDKeymap.modifierBit(for: event.keyCode) else { return nil }
            let isPressed = HIDKeymap.isModifierPressed(keyCode: event.keyCode, in: event.modifierFlags)
            return builder.modifierChanged(bit: bit, isPressed: isPressed)
        default:
            return nil
        }
    }
}
