import Foundation

struct HIDKeyboardReport: Equatable, Sendable {
    static let maxKeys = 6

    var modifier: UInt8
    var keycodes: [UInt8]

    init(modifier: UInt8 = 0, keycodes: [UInt8] = []) {
        self.modifier = modifier
        self.keycodes = Array(keycodes.prefix(Self.maxKeys))
    }

    var bootReportBytes: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes[0] = modifier
        for (index, keycode) in keycodes.prefix(Self.maxKeys).enumerated() {
            bytes[index + 2] = keycode
        }
        return bytes
    }

    var nanoKVMMessageData: Data {
        Data([0x01] + bootReportBytes)
    }
}

final class HIDKeyboardReportBuilder {
    private var modifier: UInt8 = 0
    private var pressedKeys: [UInt8] = []

    func keyDown(usage: UInt8) -> HIDKeyboardReport {
        if !pressedKeys.contains(usage), pressedKeys.count < HIDKeyboardReport.maxKeys {
            pressedKeys.append(usage)
        }
        return currentReport()
    }

    func keyUp(usage: UInt8) -> HIDKeyboardReport {
        pressedKeys.removeAll { $0 == usage }
        return currentReport()
    }

    func modifierChanged(bit: UInt8, isPressed: Bool) -> HIDKeyboardReport {
        if isPressed {
            modifier |= bit
        } else {
            modifier &= ~bit
        }
        return currentReport()
    }

    func reset() -> HIDKeyboardReport {
        modifier = 0
        pressedKeys.removeAll()
        return currentReport()
    }

    private func currentReport() -> HIDKeyboardReport {
        HIDKeyboardReport(modifier: modifier, keycodes: pressedKeys)
    }
}
