import AppKit
import KVMCore
import XCTest
@testable import KVMConsole

final class KeyEventTranslatorTests: XCTestCase {
    func test_translatesKeyDownAndKeyUpFromCGEventFields() {
        let translator = KeyEventTranslator()

        XCTAssertEqual(
            translator.report(
                for: .keyDown,
                keyCode: 0,
                flags: [],
                isAutorepeat: false,
                allowsKeyRepeat: false
            ),
            HIDKeyboardReport(modifier: 0, keycodes: [0x04])
        )

        XCTAssertEqual(
            translator.report(
                for: .keyUp,
                keyCode: 0,
                flags: [],
                isAutorepeat: false,
                allowsKeyRepeat: false
            ),
            HIDKeyboardReport()
        )
    }

    func test_ignoresKeyRepeatWhenDisabled() {
        let translator = KeyEventTranslator()

        XCTAssertNil(translator.report(
            for: .keyDown,
            keyCode: 0,
            flags: [],
            isAutorepeat: true,
            allowsKeyRepeat: false
        ))
    }

    func test_translatesModifierStateFromCGFlags() {
        let translator = KeyEventTranslator()

        XCTAssertEqual(
            translator.report(
                for: .flagsChanged,
                keyCode: 55,
                flags: .maskCommand,
                isAutorepeat: false,
                allowsKeyRepeat: false
            ),
            HIDKeyboardReport(modifier: 0x08)
        )

        XCTAssertEqual(
            translator.report(
                for: .flagsChanged,
                keyCode: 55,
                flags: [],
                isAutorepeat: false,
                allowsKeyRepeat: false
            ),
            HIDKeyboardReport()
        )
    }
}
