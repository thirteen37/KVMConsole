import Network
import XCTest
@testable import KVMCore

final class RFBProtocolTests: XCTestCase {
    func test_protocolVersionParsesAndEncodesGreeting() throws {
        let version = try RFBProtocolVersion(greeting: Data("RFB 003.008\n".utf8))

        XCTAssertEqual(version, .v3_8)
        XCTAssertEqual(RFBProtocolVersion.v3_8.wireData, Data("RFB 003.008\n".utf8))
    }

    func test_pixelFormatRoundTripsBGRAWireBytes() throws {
        let data = RFBPixelFormat.bgra.wireData
        XCTAssertEqual(
            Array(data),
            [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
        )

        var reader = RFBByteReader(data)
        XCTAssertEqual(try RFBPixelFormat(reader: &reader), .bgra)
        XCTAssertTrue(reader.isAtEnd)
    }

    func test_setEncodingsUsesBigEndianSignedEncodingValues() {
        let data = RFBClientMessage.setEncodings([.copyRect, .raw, .desktopSize, .lastRect])

        XCTAssertEqual(
            Array(data),
            [
                2, 0, 0, 4,
                0, 0, 0, 1,
                0, 0, 0, 0,
                255, 255, 255, 33,
                255, 255, 255, 32,
            ]
        )
    }

    func test_framebufferUpdateRequestWireShape() {
        let data = RFBClientMessage.framebufferUpdateRequest(
            incremental: true,
            x: 1,
            y: 2,
            width: 640,
            height: 480
        )

        XCTAssertEqual(Array(data), [3, 1, 0, 1, 0, 2, 2, 128, 1, 224])
    }

    func test_sessionProfilesConfigureAppleOnlyKeyboardEchoUpdates() {
        switch RFBSessionProfile.appleScreenSharing.inputEchoUpdatePolicy {
        case .keyboard(let minimumInterval, let trigger):
            XCTAssertEqual(minimumInterval, 0.05, accuracy: 0.001)
            XCTAssertEqual(trigger, .keyUp)
        case .disabled:
            XCTFail("Apple Screen Sharing should request keyboard echo updates")
        }

        XCTAssertEqual(RFBSessionProfile.vnc.inputEchoUpdatePolicy, .disabled)
    }

    func test_inputEchoUpdateRequesterRequiresKeyboardPolicyTriggerAndFramebufferSize() {
        let disabled = RFBInputEchoUpdateRequester(policy: .disabled)
        disabled.updateFramebufferSize(width: 1920, height: 1080)
        XCTAssertNil(disabled.updateRequestAfterKeyboardEvent(isKeyDown: true, nowUptimeNanoseconds: 1))

        let requester = RFBInputEchoUpdateRequester(policy: .keyboard(minimumInterval: 0.05, trigger: .keyUp))
        XCTAssertNil(requester.updateRequestAfterKeyboardEvent(isKeyDown: false, nowUptimeNanoseconds: 1))

        requester.updateFramebufferSize(width: 1920, height: 1080)
        XCTAssertNil(requester.updateRequestAfterKeyboardEvent(isKeyDown: true, nowUptimeNanoseconds: 1))
        let request = requester.updateRequestAfterKeyboardEvent(isKeyDown: false, nowUptimeNanoseconds: 1)!
        XCTAssertEqual(Array(request.data), [3, 1, 0, 0, 0, 0, 7, 128, 4, 56])
    }

    func test_inputEchoUpdateRequesterThrottlesRepeatedKeyboardReports() {
        let requester = RFBInputEchoUpdateRequester(policy: .keyboard(minimumInterval: 0.05, trigger: .keyUp))
        requester.updateFramebufferSize(width: 640, height: 480)

        XCTAssertNotNil(requester.updateRequestAfterKeyboardEvent(isKeyDown: false, nowUptimeNanoseconds: 1_000_000_000))
        XCTAssertNil(requester.updateRequestAfterKeyboardEvent(isKeyDown: false, nowUptimeNanoseconds: 1_049_999_999))
        XCTAssertEqual(
            Array(requester.updateRequestAfterKeyboardEvent(isKeyDown: false, nowUptimeNanoseconds: 1_050_000_000)!.data),
            [3, 1, 0, 0, 0, 0, 2, 128, 1, 224]
        )
    }

    func test_endpointPortFallsBackToRFBForOutOfRangeValues() {
        XCTAssertEqual(RFBClient.endpointPort(from: 5901), NWEndpoint.Port(rawValue: 5901)!)
        XCTAssertEqual(RFBClient.endpointPort(from: 99_999), NWEndpoint.Port(rawValue: 5900)!)
        XCTAssertEqual(RFBClient.endpointPort(from: -1), NWEndpoint.Port(rawValue: 5900)!)
    }

    func test_clientFenceResponseClearsRequestFlag() throws {
        let data = try RFBClientMessage.clientFenceResponse(
            flags: 0x8000_0005,
            payload: Data([0xaa, 0xbb])
        )

        XCTAssertEqual(
            Array(data),
            [248, 0, 0, 0, 0, 0, 0, 5, 2, 0xaa, 0xbb]
        )
    }

    func test_vncProfileRefusesAppleOnlyServers() {
        XCTAssertThrowsError(
            try RFBAuthentication.selectSecurityType(
                offered: [.appleSecurity35],
                profile: .vnc
            )
        )
    }

}
