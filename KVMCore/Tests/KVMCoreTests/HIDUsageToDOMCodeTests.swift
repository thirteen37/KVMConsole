import XCTest
@testable import KVMCore

final class HIDUsageToDOMCodeTests: XCTestCase {
    func test_mapsLettersDigitsAndNavigationKeys() {
        XCTAssertEqual(HIDUsageToDOMCode.lookup(usage: 0x04), "KeyA")
        XCTAssertEqual(HIDUsageToDOMCode.lookup(usage: 0x1D), "KeyZ")
        XCTAssertEqual(HIDUsageToDOMCode.lookup(usage: 0x1E), "Digit1")
        XCTAssertEqual(HIDUsageToDOMCode.lookup(usage: 0x27), "Digit0")
        XCTAssertEqual(HIDUsageToDOMCode.lookup(usage: 0x52), "ArrowUp")
        XCTAssertEqual(HIDUsageToDOMCode.lookup(usage: 0x4F), "ArrowRight")
    }

    func test_mapsModifiersWithSide() {
        XCTAssertEqual(HIDUsageToDOMCode.lookup(usage: 0xE0), "ControlLeft")
        XCTAssertEqual(HIDUsageToDOMCode.lookup(usage: 0xE4), "ControlRight")
        XCTAssertEqual(HIDUsageToDOMCode.modifierCode(for: .leftGUI), "MetaLeft")
        XCTAssertEqual(HIDUsageToDOMCode.modifierCode(for: .rightAlt), "AltRight")
    }

    func test_mapsFunctionAndPunctuationKeys() {
        XCTAssertEqual(HIDUsageToDOMCode.lookup(usage: 0x3A), "F1")
        XCTAssertEqual(HIDUsageToDOMCode.lookup(usage: 0x45), "F12")
        XCTAssertEqual(HIDUsageToDOMCode.lookup(usage: 0x2D), "Minus")
        XCTAssertEqual(HIDUsageToDOMCode.lookup(usage: 0x35), "Backquote")
    }
}

