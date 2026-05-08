import AppKit
import XCTest
@testable import NanoKVM

final class HIDKeymapTests: XCTestCase {
    func test_mapsCommonMacKeyCodesToHIDUsages() {
        XCTAssertEqual(HIDKeymap.usage(for: 0), 0x04)     // A
        XCTAssertEqual(HIDKeymap.usage(for: 11), 0x05)    // B
        XCTAssertEqual(HIDKeymap.usage(for: 36), 0x28)    // Return
        XCTAssertEqual(HIDKeymap.usage(for: 53), 0x29)    // Escape
        XCTAssertEqual(HIDKeymap.usage(for: 124), 0x4F)   // Right arrow
        XCTAssertEqual(HIDKeymap.usage(for: 122), 0x3A)   // F1
    }

    func test_mapsModifierKeyCodesToBits() {
        XCTAssertEqual(HIDKeymap.modifierBit(for: 59), 0x01) // left control
        XCTAssertEqual(HIDKeymap.modifierBit(for: 56), 0x02) // left shift
        XCTAssertEqual(HIDKeymap.modifierBit(for: 58), 0x04) // left option
        XCTAssertEqual(HIDKeymap.modifierBit(for: 55), 0x08) // left command
        XCTAssertEqual(HIDKeymap.modifierBit(for: 54), 0x80) // right command
    }

    func test_detectsModifierPressedFromFlags() {
        XCTAssertTrue(HIDKeymap.isModifierPressed(keyCode: 56, in: [.shift]))
        XCTAssertFalse(HIDKeymap.isModifierPressed(keyCode: 56, in: []))
        XCTAssertFalse(HIDKeymap.isModifierPressed(keyCode: 0, in: [.shift]))
    }
}
