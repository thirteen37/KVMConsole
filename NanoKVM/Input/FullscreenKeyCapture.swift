import AppKit
import Foundation

struct TripleEscapeDetector: Equatable {
    static let triggerCount = 3
    static let window: TimeInterval = 1.5

    private var timestamps: [Date] = []

    mutating func register(at timestamp: Date) -> Bool {
        timestamps.append(timestamp)
        let cutoff = timestamp.addingTimeInterval(-Self.window)
        timestamps.removeAll { $0 < cutoff }
        return timestamps.count >= Self.triggerCount
    }

    mutating func reset() {
        timestamps.removeAll()
    }
}

@MainActor
final class FullscreenKeyCaptureCoordinator {
    private static let escapeKeyCode: UInt16 = 53

    private let isCapturing: @MainActor () -> Bool
    private let onKeyboardReport: @MainActor (HIDKeyboardReport) -> Void
    private let onTripleEscape: @MainActor () -> Void

    private let builder = HIDKeyboardReportBuilder()
    private var escapeDetector = TripleEscapeDetector()
    private weak var window: NSWindow?
    private var monitor: Any?
    private var savedPresentationOptions: NSApplication.PresentationOptions?

    init(
        isCapturing: @escaping @MainActor () -> Bool,
        onKeyboardReport: @escaping @MainActor (HIDKeyboardReport) -> Void,
        onTripleEscape: @escaping @MainActor () -> Void
    ) {
        self.isCapturing = isCapturing
        self.onKeyboardReport = onKeyboardReport
        self.onTripleEscape = onTripleEscape
    }

    func start(window: NSWindow) {
        guard monitor == nil else { return }
        self.window = window

        savedPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock, .disableProcessSwitching]

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
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
        window = nil
        escapeDetector.reset()

        onKeyboardReport(builder.reset())
    }

    private func handleEvent(_ event: NSEvent) -> NSEvent? {
        guard let window, NSApp.keyWindow === window else { return event }
        guard isCapturing() else { return event }

        if event.type == .keyDown, event.keyCode == Self.escapeKeyCode {
            if escapeDetector.register(at: Date()) {
                onTripleEscape()
            }
        }

        if let report = report(for: event) {
            onKeyboardReport(report)
        }
        return nil
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
