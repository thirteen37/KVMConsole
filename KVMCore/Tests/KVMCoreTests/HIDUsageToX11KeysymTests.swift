import XCTest
@testable import KVMCore

final class HIDUsageToX11KeysymTests: XCTestCase {
    func test_mapsLettersDigitsModifiersAndNavigationKeys() {
        XCTAssertEqual(HIDUsageToX11Keysym.lookup(usage: 0x04), 0x0061)
        XCTAssertEqual(HIDUsageToX11Keysym.lookup(usage: 0x04, modifier: HIDModifierBit.leftShift.rawValue), 0x0041)
        XCTAssertEqual(HIDUsageToX11Keysym.lookup(usage: 0x27), 0x0030)
        XCTAssertEqual(HIDUsageToX11Keysym.lookup(usage: 0x27, modifier: HIDModifierBit.rightShift.rawValue), 0x0029)
        XCTAssertEqual(HIDUsageToX11Keysym.lookup(usage: 0x2D, modifier: HIDModifierBit.leftShift.rawValue), 0x005F)
        XCTAssertEqual(HIDUsageToX11Keysym.lookup(usage: 0x52), 0xff52)
        XCTAssertEqual(HIDUsageToX11Keysym.modifierKeysym(for: .leftShift), 0xffe1)
        XCTAssertEqual(HIDUsageToX11Keysym.modifierKeysym(for: .rightControl), 0xffe4)
    }

    func test_transitionsDiffModifiersAndKeys() {
        let old = HIDKeyboardReport(modifier: HIDModifierBit.leftShift.rawValue, keycodes: [0x04, 0x05])
        let new = HIDKeyboardReport(modifier: HIDModifierBit.leftControl.rawValue, keycodes: [0x05, 0x06])

        XCTAssertEqual(
            HIDUsageToX11Keysym.transitions(from: old, to: new),
            [
                .init(keysym: 0x0041, isDown: false),
                .init(keysym: 0x0042, isDown: false),
                .init(keysym: 0xffe1, isDown: false),
                .init(keysym: 0xffe3, isDown: true),
                .init(keysym: 0x0062, isDown: true),
                .init(keysym: 0x0063, isDown: true),
            ]
        )
    }

    func test_modifierChangeRekeysHeldNonModifierKeys() {
        let a = HIDKeyboardReport(keycodes: [0x04])
        let shiftedA = HIDKeyboardReport(modifier: HIDModifierBit.leftShift.rawValue, keycodes: [0x04])

        XCTAssertEqual(
            HIDUsageToX11Keysym.transitions(from: a, to: shiftedA),
            [
                .init(keysym: 0x0061, isDown: false),
                .init(keysym: 0xffe1, isDown: true),
                .init(keysym: 0x0041, isDown: true),
            ]
        )

        XCTAssertEqual(
            HIDUsageToX11Keysym.transitions(from: shiftedA, to: HIDKeyboardReport(modifier: HIDModifierBit.leftShift.rawValue)),
            [
                .init(keysym: 0x0041, isDown: false),
            ]
        )
    }

    func test_shiftedStrokePressesModifierBeforeShiftedKeysymAndReleasesKeyFirst() {
        let shiftedA = HIDKeyboardReport(modifier: HIDModifierBit.leftShift.rawValue, keycodes: [0x04])

        XCTAssertEqual(
            HIDUsageToX11Keysym.transitions(from: HIDKeyboardReport(), to: shiftedA),
            [
                .init(keysym: 0xffe1, isDown: true),
                .init(keysym: 0x0041, isDown: true),
            ]
        )

        XCTAssertEqual(
            HIDUsageToX11Keysym.transitions(from: shiftedA, to: HIDKeyboardReport()),
            [
                .init(keysym: 0x0041, isDown: false),
                .init(keysym: 0xffe1, isDown: false),
            ]
        )
    }

    func test_shiftedPunctuationUsesCharacterKeysym() {
        let exclamation = HIDKeyboardReport(modifier: HIDModifierBit.leftShift.rawValue, keycodes: [0x1E])

        XCTAssertEqual(
            HIDUsageToX11Keysym.transitions(from: HIDKeyboardReport(), to: exclamation),
            [
                .init(keysym: 0xffe1, isDown: true),
                .init(keysym: 0x0021, isDown: true),
            ]
        )
    }

    func test_repeatTransitionsPulseLastPressedKeyWithCurrentModifiers() {
        let report = HIDKeyboardReport(modifier: HIDModifierBit.leftShift.rawValue, keycodes: [0x04, 0x05])

        XCTAssertEqual(
            HIDUsageToX11Keysym.repeatTransitions(for: report),
            [
                .init(keysym: 0x0042, isDown: false),
                .init(keysym: 0x0042, isDown: true),
            ]
        )
    }

    func test_repeatTransitionsIgnoreModifierOnlyReports() {
        let report = HIDKeyboardReport(modifier: HIDModifierBit.leftShift.rawValue)

        XCTAssertEqual(HIDUsageToX11Keysym.repeatTransitions(for: report), [])
    }
}
