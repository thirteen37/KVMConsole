#if os(macOS)
import Foundation

/// Pure encoder for the CH9329 USB-HID bridge used by the Sipeed NanoKVM USB stick.
///
/// Frame layout: `0x57 0xAB | address | command | length | data... | checksum`
/// where `checksum = sum(preceding bytes) & 0xff`.
public enum CH9329Protocol {
    public static let header: [UInt8] = [0x57, 0xAB]
    public static let defaultAddress: UInt8 = 0x00
    public static let baudRate: Int32 = 57_600

    public enum Command {
        public static let sendKeyboardGeneralData: UInt8 = 0x02
        public static let sendMouseAbsoluteData: UInt8 = 0x04
    }

    /// Build a packet with the standard header, address, command, length, payload, and checksum.
    public static func packet(command: UInt8, data: Data) -> Data {
        var bytes = Data()
        bytes.append(contentsOf: header)
        bytes.append(defaultAddress)
        bytes.append(command)
        bytes.append(UInt8(data.count & 0xff))
        bytes.append(data)
        bytes.append(checksum(of: bytes))
        return bytes
    }

    /// Encode a keyboard report (HID boot keyboard format) as a `0x02` command packet.
    public static func keyboardPacket(_ report: HIDKeyboardReport) -> Data {
        let payload = report.bootReportBytes
        return packet(command: Command.sendKeyboardGeneralData, data: Data(payload))
    }

    /// Encode an absolute-mouse report as a `0x04` command packet.
    ///
    /// The CH9329 absolute report payload is `[0x02, buttons, xLo, xHi, yLo, yHi, wheel]`,
    /// where `x` and `y` are 12-bit values in `0...4095`. `HIDMouseAbsoluteReport` carries
    /// the same NanoKVM-style 16-bit range (`1...32767`) used elsewhere in the app, so we
    /// rescale here.
    public static func absoluteMousePacket(_ report: HIDMouseAbsoluteReport) -> Data {
        let scaledX = scaleTo12Bit(report.x)
        let scaledY = scaleTo12Bit(report.y)
        let payload: [UInt8] = [
            0x02,
            report.buttons,
            UInt8(scaledX & 0x00ff),
            UInt8((scaledX & 0xff00) >> 8),
            UInt8(scaledY & 0x00ff),
            UInt8((scaledY & 0xff00) >> 8),
            UInt8(bitPattern: report.wheel),
        ]
        return packet(command: Command.sendMouseAbsoluteData, data: Data(payload))
    }

    static func checksum(of bytes: Data) -> UInt8 {
        var sum: UInt32 = 0
        for byte in bytes {
            sum &+= UInt32(byte)
        }
        return UInt8(sum & 0xff)
    }

    /// Maps a value in HIDMouseAbsoluteReport's 16-bit range (`1...32767`) into CH9329's
    /// 12-bit range (`0...4095`). The mapping is linear with rounding to nearest.
    static func scaleTo12Bit(_ value: UInt16) -> UInt16 {
        let clamped = min(UInt32(value), 32_767)
        let scaled = (clamped * 4_095 + 16_383) / 32_767
        return UInt16(min(scaled, 4_095))
    }
}
#endif
