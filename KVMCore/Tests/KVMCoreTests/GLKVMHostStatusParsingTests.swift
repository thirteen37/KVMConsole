import XCTest
@testable import KVMCore

final class GLKVMHostStatusParsingTests: XCTestCase {
    func test_atxPowerStringOnParsesAsOn() {
        let event: [String: Any] = [
            "busy": false,
            "enabled": true,
            "leds": ["hdd": false, "power": false],
            "power": "on",
        ]
        XCTAssertEqual(GLKVMControlSocket.parseATXPower(event), .on)
    }

    func test_atxPowerStringOffParsesAsOff() {
        let event: [String: Any] = ["power": "off"]
        XCTAssertEqual(GLKVMControlSocket.parseATXPower(event), .off)
    }

    func test_atxIgnoresLedsPowerField() {
        // leds.power is the LED indicator, not host power state; ignore it.
        let event: [String: Any] = ["leds": ["power": true]]
        XCTAssertNil(GLKVMControlSocket.parseATXPower(event))
    }

    func test_atxEventWithoutPowerFieldReturnsNil() {
        let event: [String: Any] = ["busy": false, "enabled": true]
        XCTAssertNil(GLKVMControlSocket.parseATXPower(event))
    }

    func test_atxPowerStringIsCaseInsensitive() {
        XCTAssertEqual(GLKVMControlSocket.parseATXPower(["power": "ON"]), .on)
        XCTAssertEqual(GLKVMControlSocket.parseATXPower(["power": "Off"]), .off)
    }

    func test_atxPowerUnknownStringReturnsNil() {
        XCTAssertNil(GLKVMControlSocket.parseATXPower(["power": "unknown"]))
    }

    func test_streamerHDMISignalTrue() {
        let event: [String: Any] = [
            "streamer": [
                "hdmi": ["signal": true],
                "source": ["online": true],
            ]
        ]
        XCTAssertEqual(GLKVMControlSocket.parseStreamerHDMISignal(event), true)
    }

    func test_streamerHDMISignalFalse() {
        let event: [String: Any] = [
            "streamer": ["hdmi": ["signal": false]]
        ]
        XCTAssertEqual(GLKVMControlSocket.parseStreamerHDMISignal(event), false)
    }

    func test_streamerCapabilityEventReturnsNil() {
        // Initial event after subscription advertises capabilities only, with streamer = null.
        let event: [String: Any] = [
            "features": ["h264": true],
            "params": ["h264_bitrate": 5000],
            "streamer": NSNull(),
        ]
        XCTAssertNil(GLKVMControlSocket.parseStreamerHDMISignal(event))
    }

    func test_streamerEventWithoutHDMIReturnsNil() {
        let event: [String: Any] = [
            "streamer": ["source": ["online": true]]
        ]
        XCTAssertNil(GLKVMControlSocket.parseStreamerHDMISignal(event))
    }

    func test_topLevelHDMIIsNotParsed() {
        // Defensive: PiKVM-style top-level shape is *not* what GLKVM sends.
        let event: [String: Any] = ["hdmi": ["signal": true]]
        XCTAssertNil(GLKVMControlSocket.parseStreamerHDMISignal(event))
    }
}
