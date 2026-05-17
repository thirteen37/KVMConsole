import Foundation

public enum HIDUsageToDOMCode {
    private static let table: [UInt8: String] = [
        0x04: "KeyA", 0x05: "KeyB", 0x06: "KeyC", 0x07: "KeyD", 0x08: "KeyE",
        0x09: "KeyF", 0x0A: "KeyG", 0x0B: "KeyH", 0x0C: "KeyI", 0x0D: "KeyJ",
        0x0E: "KeyK", 0x0F: "KeyL", 0x10: "KeyM", 0x11: "KeyN", 0x12: "KeyO",
        0x13: "KeyP", 0x14: "KeyQ", 0x15: "KeyR", 0x16: "KeyS", 0x17: "KeyT",
        0x18: "KeyU", 0x19: "KeyV", 0x1A: "KeyW", 0x1B: "KeyX", 0x1C: "KeyY",
        0x1D: "KeyZ",
        0x1E: "Digit1", 0x1F: "Digit2", 0x20: "Digit3", 0x21: "Digit4", 0x22: "Digit5",
        0x23: "Digit6", 0x24: "Digit7", 0x25: "Digit8", 0x26: "Digit9", 0x27: "Digit0",
        0x28: "Enter", 0x29: "Escape", 0x2A: "Backspace", 0x2B: "Tab", 0x2C: "Space",
        0x2D: "Minus", 0x2E: "Equal", 0x2F: "BracketLeft", 0x30: "BracketRight",
        0x31: "Backslash", 0x32: "Backslash", 0x33: "Semicolon", 0x34: "Quote",
        0x35: "Backquote", 0x36: "Comma", 0x37: "Period", 0x38: "Slash",
        0x39: "CapsLock",
        0x3A: "F1", 0x3B: "F2", 0x3C: "F3", 0x3D: "F4", 0x3E: "F5", 0x3F: "F6",
        0x40: "F7", 0x41: "F8", 0x42: "F9", 0x43: "F10", 0x44: "F11", 0x45: "F12",
        0x46: "PrintScreen", 0x47: "ScrollLock", 0x48: "Pause", 0x49: "Insert",
        0x4A: "Home", 0x4B: "PageUp", 0x4C: "Delete", 0x4D: "End", 0x4E: "PageDown",
        0x4F: "ArrowRight", 0x50: "ArrowLeft", 0x51: "ArrowDown", 0x52: "ArrowUp",
        0x53: "NumLock", 0x54: "NumpadDivide", 0x55: "NumpadMultiply", 0x56: "NumpadSubtract",
        0x57: "NumpadAdd", 0x58: "NumpadEnter", 0x59: "Numpad1", 0x5A: "Numpad2",
        0x5B: "Numpad3", 0x5C: "Numpad4", 0x5D: "Numpad5", 0x5E: "Numpad6",
        0x5F: "Numpad7", 0x60: "Numpad8", 0x61: "Numpad9", 0x62: "Numpad0",
        0x63: "NumpadDecimal",
        0x64: "IntlBackslash", 0x65: "ContextMenu",
    ]

    private static let modifierUsageTable: [UInt8: String] = [
        0xE0: "ControlLeft",
        0xE1: "ShiftLeft",
        0xE2: "AltLeft",
        0xE3: "MetaLeft",
        0xE4: "ControlRight",
        0xE5: "ShiftRight",
        0xE6: "AltRight",
        0xE7: "MetaRight",
    ]

    public static func lookup(usage: UInt8) -> String? {
        if let modifier = modifierUsageTable[usage] {
            return modifier
        }
        return table[usage]
    }

    public static func modifierCode(for bit: HIDModifierBit) -> String {
        switch bit {
        case .leftControl: return "ControlLeft"
        case .leftShift: return "ShiftLeft"
        case .leftAlt: return "AltLeft"
        case .leftGUI: return "MetaLeft"
        case .rightControl: return "ControlRight"
        case .rightShift: return "ShiftRight"
        case .rightAlt: return "AltRight"
        case .rightGUI: return "MetaRight"
        }
    }
}

