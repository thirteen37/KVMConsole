@preconcurrency import ApplicationServices
@preconcurrency import AppKit
import Foundation
import KVMCore

@MainActor
final class FullscreenKeyCaptureCoordinator {
    private static let escapeKeyCode: UInt16 = 53
    private static let topEdgeRevealZone: CGFloat = 4
    private static let topEdgeHideZone: CGFloat = 60

    private let isCapturing: @MainActor () -> Bool
    private let allowsKeyRepeat: Bool
    private let onKeyboardReport: @MainActor (HIDKeyboardReport) -> Void
    private let onTripleEscape: @MainActor () -> Void
    private let onTopEdgeHover: @MainActor () -> Void
    private let onTopEdgeLeft: @MainActor () -> Void
    private let onCaptureModeChange: @MainActor (FullscreenKeyCaptureMode) -> Void

    private let keyTranslator = KeyEventTranslator()
    private var escapeDetector = TripleEscapeDetector()
    private weak var window: NSWindow?
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var savedPresentationOptions: NSApplication.PresentationOptions?
    private var savedAcceptsMouseMovedEvents: Bool?
    private var captureMode: FullscreenKeyCaptureMode = .off

    init(
        isCapturing: @escaping @MainActor () -> Bool,
        allowsKeyRepeat: Bool,
        onKeyboardReport: @escaping @MainActor (HIDKeyboardReport) -> Void,
        onTripleEscape: @escaping @MainActor () -> Void,
        onTopEdgeHover: @escaping @MainActor () -> Void,
        onTopEdgeLeft: @escaping @MainActor () -> Void,
        onCaptureModeChange: @escaping @MainActor (FullscreenKeyCaptureMode) -> Void
    ) {
        self.isCapturing = isCapturing
        self.allowsKeyRepeat = allowsKeyRepeat
        self.onKeyboardReport = onKeyboardReport
        self.onTripleEscape = onTripleEscape
        self.onTopEdgeHover = onTopEdgeHover
        self.onTopEdgeLeft = onTopEdgeLeft
        self.onCaptureModeChange = onCaptureModeChange
    }

    func start(window: NSWindow) {
        guard localMonitor == nil, eventTap == nil else { return }
        self.window = window

        savedPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [
            .autoHideMenuBar,
            .autoHideDock,
            .disableProcessSwitching,
            .disableHideApplication,
            .disableForceQuit
        ]

        savedAcceptsMouseMovedEvents = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true

        let hasAllKeys = requestAccessibilityTrustIfNeeded() && installEventTap()
        captureMode = hasAllKeys ? .allKeys : .limited
        onCaptureModeChange(captureMode)

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: hasAllKeys ? [.mouseMoved] : [.keyDown, .keyUp, .flagsChanged, .mouseMoved]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleLocalEvent(event)
        }
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
        removeEventTap()

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
        captureMode = .off
        onCaptureModeChange(.off)

        onKeyboardReport(keyTranslator.reset())
    }

    private func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        guard let window, NSApp.keyWindow === window else { return event }

        if event.type == .mouseMoved {
            handleMouseMoved(event, in: window)
            return event
        }

        guard isCapturing() else { return event }

        if event.type == .keyDown, !event.isARepeat, event.keyCode == Self.escapeKeyCode {
            if escapeDetector.register(at: Date()) {
                escapeDetector.reset()
                onTripleEscape()
            }
        }

        if let report = keyTranslator.report(for: event, allowsKeyRepeat: allowsKeyRepeat) {
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

    private func requestAccessibilityTrustIfNeeded() -> Bool {
        guard !AXIsProcessTrusted() else { return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func installEventTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: userInfo
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        self.eventTap = eventTap
        eventTapRunLoopSource = source
        return true
    }

    private func removeEventTap() {
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
        }
        eventTapRunLoopSource = nil

        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
    }

    fileprivate func handleCGEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let window, NSApp.keyWindow === window else {
            return Unmanaged.passUnretained(event)
        }

        guard isCapturing() else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if type == .keyDown, !isAutorepeat, keyCode == Self.escapeKeyCode {
            if escapeDetector.register(at: Date()) {
                escapeDetector.reset()
                onTripleEscape()
            }
        }

        if let report = keyTranslator.report(
            for: type,
            keyCode: keyCode,
            flags: event.flags,
            isAutorepeat: isAutorepeat,
            allowsKeyRepeat: allowsKeyRepeat
        ) {
            onKeyboardReport(report)
        }

        return nil
    }
}

private let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let coordinator = Unmanaged<FullscreenKeyCaptureCoordinator>
        .fromOpaque(userInfo)
        .takeUnretainedValue()

    return MainActor.assumeIsolated {
        coordinator.handleCGEvent(type: type, event: event)
    }
}
