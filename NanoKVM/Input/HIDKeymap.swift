import AppKit
import NanoKVMCore

enum HIDKeymap {
    static func usage(for keyCode: UInt16) -> UInt8? {
        usageByMacKeyCode[keyCode]
    }

    static func modifierBit(for keyCode: UInt16) -> UInt8? {
        modifierByMacKeyCode[keyCode]?.bit
    }

    static func isModifierPressed(keyCode: UInt16, in flags: NSEvent.ModifierFlags) -> Bool {
        guard let modifier = modifierByMacKeyCode[keyCode] else { return false }
        return flags.contains(modifier.flag)
    }

    private static let modifierByMacKeyCode: [UInt16: (bit: UInt8, flag: NSEvent.ModifierFlags)] = [
        59: (HIDModifierBit.leftControl.rawValue, .control),   // left control
        56: (HIDModifierBit.leftShift.rawValue, .shift),        // left shift
        58: (HIDModifierBit.leftAlt.rawValue, .option),         // left option
        55: (HIDModifierBit.leftGUI.rawValue, .command),        // left command
        62: (HIDModifierBit.rightControl.rawValue, .control),   // right control
        60: (HIDModifierBit.rightShift.rawValue, .shift),       // right shift
        61: (HIDModifierBit.rightAlt.rawValue, .option),        // right option
        54: (HIDModifierBit.rightGUI.rawValue, .command)        // right command
    ]

    private static let usageByMacKeyCode: [UInt16: UInt8] = [
        // Letters, physical US QWERTY positions.
        0: 0x04,   // A
        11: 0x05,  // B
        8: 0x06,   // C
        2: 0x07,   // D
        14: 0x08,  // E
        3: 0x09,   // F
        5: 0x0A,   // G
        4: 0x0B,   // H
        34: 0x0C,  // I
        38: 0x0D,  // J
        40: 0x0E,  // K
        37: 0x0F,  // L
        46: 0x10,  // M
        45: 0x11,  // N
        31: 0x12,  // O
        35: 0x13,  // P
        12: 0x14,  // Q
        15: 0x15,  // R
        1: 0x16,   // S
        17: 0x17,  // T
        32: 0x18,  // U
        9: 0x19,   // V
        13: 0x1A,  // W
        7: 0x1B,   // X
        16: 0x1C,  // Y
        6: 0x1D,   // Z

        // Number row.
        18: 0x1E,  // 1
        19: 0x1F,  // 2
        20: 0x20,  // 3
        21: 0x21,  // 4
        23: 0x22,  // 5
        22: 0x23,  // 6
        26: 0x24,  // 7
        28: 0x25,  // 8
        25: 0x26,  // 9
        29: 0x27,  // 0

        36: 0x28,  // Return
        53: 0x29,  // Escape
        51: 0x2A,  // Delete / Backspace
        48: 0x2B,  // Tab
        49: 0x2C,  // Space
        27: 0x2D,  // -
        24: 0x2E,  // =
        33: 0x2F,  // [
        30: 0x30,  // ]
        42: 0x31,  // Backslash
        41: 0x33,  // ;
        39: 0x34,  // '
        50: 0x35,  // `
        43: 0x36,  // ,
        47: 0x37,  // .
        44: 0x38,  // /
        57: 0x39,  // Caps Lock

        // Function keys.
        122: 0x3A, // F1
        120: 0x3B, // F2
        99: 0x3C,  // F3
        118: 0x3D, // F4
        96: 0x3E,  // F5
        97: 0x3F,  // F6
        98: 0x40,  // F7
        100: 0x41, // F8
        101: 0x42, // F9
        109: 0x43, // F10
        103: 0x44, // F11
        111: 0x45, // F12

        // Navigation.
        114: 0x49, // Insert / Help
        115: 0x4A, // Home
        116: 0x4B, // Page Up
        117: 0x4C, // Forward Delete
        119: 0x4D, // End
        121: 0x4E, // Page Down
        124: 0x4F, // Right
        123: 0x50, // Left
        125: 0x51, // Down
        126: 0x52, // Up

        // Numeric keypad.
        71: 0x53,  // Clear / Num Lock
        75: 0x54,  // /
        67: 0x55,  // *
        78: 0x56,  // -
        69: 0x57,  // +
        76: 0x58,  // Enter
        83: 0x59,  // 1
        84: 0x5A,  // 2
        85: 0x5B,  // 3
        86: 0x5C,  // 4
        87: 0x5D,  // 5
        88: 0x5E,  // 6
        89: 0x5F,  // 7
        91: 0x60,  // 8
        92: 0x61,  // 9
        82: 0x62,  // 0
        65: 0x63   // .
    ]
}
