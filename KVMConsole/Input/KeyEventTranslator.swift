import AppKit
import KVMCore

final class KeyEventTranslator {
    private let builder = HIDKeyboardReportBuilder()

    func report(
        for eventType: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isAutorepeat: Bool,
        allowsKeyRepeat: Bool
    ) -> HIDKeyboardReport? {
        switch eventType {
        case .keyDown:
            guard !isAutorepeat || allowsKeyRepeat else { return nil }
            guard let usage = HIDKeymap.usage(for: keyCode) else { return nil }
            return builder.keyDown(usage: usage)
        case .keyUp:
            guard let usage = HIDKeymap.usage(for: keyCode) else { return nil }
            return builder.keyUp(usage: usage)
        case .flagsChanged:
            guard let bit = HIDKeymap.modifierBit(for: keyCode) else { return nil }
            let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
            let isPressed = HIDKeymap.isModifierPressed(keyCode: keyCode, in: modifierFlags)
            return builder.modifierChanged(bit: bit, isPressed: isPressed)
        default:
            return nil
        }
    }

    func report(for event: NSEvent, allowsKeyRepeat: Bool) -> HIDKeyboardReport? {
        let eventType = CGEventType(nsEventType: event.type)
        return report(
            for: eventType,
            keyCode: event.keyCode,
            flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)),
            isAutorepeat: event.isARepeat,
            allowsKeyRepeat: allowsKeyRepeat
        )
    }

    func reset() -> HIDKeyboardReport {
        builder.reset()
    }
}

private extension CGEventType {
    init(nsEventType: NSEvent.EventType) {
        switch nsEventType {
        case .keyDown:
            self = .keyDown
        case .keyUp:
            self = .keyUp
        case .flagsChanged:
            self = .flagsChanged
        default:
            self = .null
        }
    }
}
