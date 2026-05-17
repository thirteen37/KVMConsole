import XCTest
@testable import KVMCore

final class GLKVMEventEncodingTests: XCTestCase {
    func test_keyboardDiffEmitsModifierAndKeyTransitions() {
        let old = HIDKeyboardReport(modifier: HIDModifierBit.leftControl.rawValue, keycodes: [0x04])
        let new = HIDKeyboardReport(modifier: HIDModifierBit.rightGUI.rawValue, keycodes: [0x05])

        let events = GLKVMControlSocket.keyboardEvents(from: old, to: new)

        XCTAssertEqual(events, [
            .key(code: "ControlLeft", isPressed: false),
            .key(code: "MetaRight", isPressed: true),
            .key(code: "KeyA", isPressed: false),
            .key(code: "KeyB", isPressed: true),
        ])
    }

    func test_keyEventEncodesGLKVMBinaryShape() {
        let data = GLKVMControlSocket.encodeBinary(.key(code: "KeyA", isPressed: true))
        XCTAssertEqual(Array(data), [0x01, 0x01, 0x4b, 0x65, 0x79, 0x41])
    }

    func test_mouseMoveCoordinateConversionUsesPiKVMCenteredRange() {
        XCTAssertEqual(GLKVMControlSocket.pikvmCoordinate(from: 1), -32_768)
        XCTAssertEqual(GLKVMControlSocket.pikvmCoordinate(from: 32_768), 32_767)
    }

    func test_mouseButtonEventsUseGLKVMButtonNames() {
        XCTAssertEqual(GLKVMControlSocket.mouseButtonEvents(from: 0, to: 0b0001), [
            .mouseButton(button: "left", isPressed: true)
        ])
        XCTAssertEqual(GLKVMControlSocket.mouseButtonEvents(from: 0b0010, to: 0), [
            .mouseButton(button: "right", isPressed: false)
        ])
        XCTAssertEqual(GLKVMControlSocket.mouseButtonEvents(from: 0b0100, to: 0), [
            .mouseButton(button: "middle", isPressed: false)
        ])
    }

    func test_mouseButtonEncodesGLKVMBinaryShape() {
        let data = GLKVMControlSocket.encodeBinary(.mouseButton(button: "left", isPressed: false))
        XCTAssertEqual(Array(data), [0x02, 0x00, 0x6c, 0x65, 0x66, 0x74])
    }

    func test_mouseMoveEncodesGLKVMBinaryShape() {
        let data = GLKVMControlSocket.encodeBinary(.mouseMove(x: -32_768, y: 32_767))
        XCTAssertEqual(Array(data), [0x03, 0x80, 0x00, 0x7f, 0xff])
    }

    func test_mouseWheelEncodesGLKVMBinaryShape() {
        let data = GLKVMControlSocket.encodeBinary(.mouseWheel(x: 0, y: -5))
        XCTAssertEqual(Array(data), [0x05, 0x00, 0x00, 0xfb])
    }
}
