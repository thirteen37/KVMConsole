import Foundation

public enum HIDModifierBit: UInt8, CaseIterable, Sendable {
    case leftControl = 0x01
    case leftShift = 0x02
    case leftAlt = 0x04
    case leftGUI = 0x08
    case rightControl = 0x10
    case rightShift = 0x20
    case rightAlt = 0x40
    case rightGUI = 0x80

    public static func bit(forHIDUsage usage: UInt8) -> UInt8? {
        switch usage {
        case 0xE0: return leftControl.rawValue
        case 0xE1: return leftShift.rawValue
        case 0xE2: return leftAlt.rawValue
        case 0xE3: return leftGUI.rawValue
        case 0xE4: return rightControl.rawValue
        case 0xE5: return rightShift.rawValue
        case 0xE6: return rightAlt.rawValue
        case 0xE7: return rightGUI.rawValue
        default: return nil
        }
    }
}
