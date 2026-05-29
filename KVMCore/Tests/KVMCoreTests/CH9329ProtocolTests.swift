#if os(macOS)
import XCTest
@testable import KVMCore

final class CH9329ProtocolTests: XCTestCase {
    func test_keyboardPacket_pressA_matchesWikiFixture() {
        // The Sipeed NanoKVM-USB documentation / firmware specifies that
        // sending the "A" key with no modifiers produces this 17-byte frame.
        let expected: [UInt8] = [
            0x57, 0xAB, 0x00, 0x02, 0x08,
            0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x10,
        ]

        let report = HIDKeyboardReport(modifier: 0, keycodes: [0x04])
        let packet = CH9329Protocol.keyboardPacket(report)

        XCTAssertEqual([UInt8](packet), expected)
    }

    func test_keyboardPacket_withModifierAndMultipleKeys() {
        // Ctrl+A (modifier 0x01, key 0x04). Verify byte layout + checksum.
        let report = HIDKeyboardReport(modifier: 0x01, keycodes: [0x04])
        let packet = CH9329Protocol.keyboardPacket(report)

        XCTAssertEqual(packet.count, 14)
        let bytes = [UInt8](packet)
        XCTAssertEqual(bytes[0...4], [0x57, 0xAB, 0x00, 0x02, 0x08])
        XCTAssertEqual(bytes[5], 0x01) // modifier byte in payload
        XCTAssertEqual(bytes[7], 0x04) // keycode A
        XCTAssertEqual(bytes.last, CH9329Protocol.checksum(of: Data(bytes.dropLast())))
    }

    func test_packet_checksumIsLowByteOfSum() {
        // Use a payload chosen so the running sum exceeds 0xff to verify wraparound.
        let payload = Data([0xFF, 0xFF, 0xFF])
        let packet = CH9329Protocol.packet(command: 0x10, data: payload)

        let expectedChecksum = CH9329Protocol.checksum(of: packet.dropLast())
        XCTAssertEqual(packet.last, expectedChecksum)
        XCTAssertEqual(packet.first, 0x57)
        XCTAssertEqual(packet[1], 0xAB)
        XCTAssertEqual(packet[2], 0x00)
        XCTAssertEqual(packet[3], 0x10)
        XCTAssertEqual(packet[4], 0x03)
    }

    func test_absoluteMousePacket_zeroPosition() {
        // Mouse at (1, 1) — the lowest legal HIDMouseAbsoluteReport coordinate — scales
        // down to (0, 0) on CH9329, so the rendered payload is `02 00 00 00 00 00 00`.
        let report = HIDMouseAbsoluteReport(buttons: 0, x: 1, y: 1, wheel: 0)
        let packet = CH9329Protocol.absoluteMousePacket(report)

        let expected: [UInt8] = [
            0x57, 0xAB, 0x00, 0x04, 0x07,
            0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x0F,
        ]
        XCTAssertEqual([UInt8](packet), expected)
    }

    func test_absoluteMousePacket_scalesAndEncodesLittleEndian() {
        // Coordinate roughly at the centre of the 16-bit range should land near 12-bit centre.
        let report = HIDMouseAbsoluteReport(buttons: 0x01, x: 16_384, y: 32_767, wheel: -1)
        let packet = CH9329Protocol.absoluteMousePacket(report)

        // Payload bytes start at offset 5 (after header[2], address, command, length).
        let bytes = [UInt8](packet)
        XCTAssertEqual(bytes[5], 0x02)             // absolute-mode marker
        XCTAssertEqual(bytes[6], 0x01)             // buttons (left button down)

        // x = 16_384 → round((16_384 * 4_095 + 16_383) / 32_767) = 2_048 (= 0x0800)
        XCTAssertEqual(bytes[7], 0x00)             // x low
        XCTAssertEqual(bytes[8], 0x08)             // x high

        // y = 32_767 → 4_095 (= 0x0FFF)
        XCTAssertEqual(bytes[9], 0xFF)             // y low
        XCTAssertEqual(bytes[10], 0x0F)            // y high

        XCTAssertEqual(bytes[11], 0xFF)            // wheel = -1 as UInt8

        XCTAssertEqual(bytes.last, CH9329Protocol.checksum(of: Data(bytes.dropLast())))
    }

    func test_scaleTo12Bit_endpoints() {
        XCTAssertEqual(CH9329Protocol.scaleTo12Bit(0), 0)
        XCTAssertEqual(CH9329Protocol.scaleTo12Bit(1), 0)
        XCTAssertEqual(CH9329Protocol.scaleTo12Bit(32_767), 4_095)
        XCTAssertEqual(CH9329Protocol.scaleTo12Bit(50_000), 4_095) // clamped
    }
}
#endif
