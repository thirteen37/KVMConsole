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

    func test_sessionProfilesConfigureAppleKeyboardEchoUpdatesForBothEdges() {
        switch RFBSessionProfile.appleScreenSharing.inputEchoUpdatePolicy {
        case .keyboard(let minimumInterval, let trigger):
            XCTAssertEqual(minimumInterval, 0.025, accuracy: 0.001)
            XCTAssertEqual(trigger, .any)
        case .disabled:
            XCTFail("Apple Screen Sharing should request keyboard echo updates")
        }

        XCTAssertEqual(RFBSessionProfile.vnc.inputEchoUpdatePolicy, .disabled)
    }

    func test_appleScreenSharingProfileLeavesContinuousUpdatesOff() {
        // Apple's server doesn't honour `EnableContinuousUpdates` — when we
        // sent it (message 150) the server stopped delivering any further
        // framebuffer updates on the connection. Keep CU off here.
        XCTAssertFalse(RFBSessionProfile.appleScreenSharing.usesContinuousUpdates)
        XCTAssertFalse(RFBSessionProfile.vnc.usesContinuousUpdates)
    }

    func test_appleScreenSharingProfileDoesNotPollFramebuffer() {
        // 30 Hz polling overloaded the decoder without lowering the
        // server-bound input-to-wire latency floor; leave the hook
        // available behind a profile flag for non-Apple targets but
        // keep it off for Apple Screen Sharing itself.
        XCTAssertNil(RFBSessionProfile.appleScreenSharing.framebufferPollInterval)
        XCTAssertNil(RFBSessionProfile.vnc.framebufferPollInterval)
    }

    func test_enableContinuousUpdatesWireShape() {
        let data = RFBClientMessage.enableContinuousUpdates(
            enable: true,
            x: 0,
            y: 0,
            width: 1920,
            height: 1080
        )
        XCTAssertEqual(Array(data), [150, 1, 0, 0, 0, 0, 7, 128, 4, 56])
    }

    func test_enableContinuousUpdatesDisableEncodesZeroEnableByte() {
        let data = RFBClientMessage.enableContinuousUpdates(
            enable: false,
            x: 16,
            y: 32,
            width: 640,
            height: 480
        )
        XCTAssertEqual(Array(data), [150, 0, 0, 16, 0, 32, 2, 128, 1, 224])
    }

    func test_continuousUpdatesEncodingValueMatchesCommunityExtension() {
        XCTAssertEqual(RFBEncoding.continuousUpdates.rawValue, -313)
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

    func test_inputEchoUpdateRequesterAnyTriggerEmitsOnEitherEdge() {
        let requester = RFBInputEchoUpdateRequester(policy: .keyboard(minimumInterval: 0.05, trigger: .any))
        requester.updateFramebufferSize(width: 640, height: 480)

        XCTAssertNotNil(requester.updateRequestAfterKeyboardEvent(isKeyDown: true, nowUptimeNanoseconds: 1_000_000_000))
        XCTAssertNil(requester.updateRequestAfterKeyboardEvent(isKeyDown: false, nowUptimeNanoseconds: 1_001_000_000))
        XCTAssertNotNil(requester.updateRequestAfterKeyboardEvent(isKeyDown: false, nowUptimeNanoseconds: 1_050_000_001))
    }

    func test_inputEchoUpdateRequesterTransitionsBatchingHonorsTrigger() {
        let upRequester = RFBInputEchoUpdateRequester(policy: .keyboard(minimumInterval: 0.05, trigger: .keyUp))
        upRequester.updateFramebufferSize(width: 640, height: 480)
        let downOnly = [HIDUsageToX11Keysym.KeyTransition(keysym: 0x61, isDown: true)]
        XCTAssertNil(upRequester.updateRequestAfterTransitions(downOnly, nowUptimeNanoseconds: 1))
        let downThenUp = [
            HIDUsageToX11Keysym.KeyTransition(keysym: 0x61, isDown: true),
            HIDUsageToX11Keysym.KeyTransition(keysym: 0x61, isDown: false),
        ]
        XCTAssertNotNil(upRequester.updateRequestAfterTransitions(downThenUp, nowUptimeNanoseconds: 2))

        let downRequester = RFBInputEchoUpdateRequester(policy: .keyboard(minimumInterval: 0.05, trigger: .keyDown))
        downRequester.updateFramebufferSize(width: 640, height: 480)
        let upOnly = [HIDUsageToX11Keysym.KeyTransition(keysym: 0x61, isDown: false)]
        XCTAssertNil(downRequester.updateRequestAfterTransitions(upOnly, nowUptimeNanoseconds: 1))
        XCTAssertNotNil(downRequester.updateRequestAfterTransitions(downThenUp, nowUptimeNanoseconds: 2))

        let anyRequester = RFBInputEchoUpdateRequester(policy: .keyboard(minimumInterval: 0.05, trigger: .any))
        anyRequester.updateFramebufferSize(width: 640, height: 480)
        XCTAssertNotNil(anyRequester.updateRequestAfterTransitions(downOnly, nowUptimeNanoseconds: 1))
        XCTAssertNil(anyRequester.updateRequestAfterTransitions(upOnly, nowUptimeNanoseconds: 2))
        XCTAssertNotNil(anyRequester.updateRequestAfterTransitions(upOnly, nowUptimeNanoseconds: 1 + 50_000_000))
    }

    func test_inputEchoUpdateRequesterTransitionsRequiresFramebufferSize() {
        let requester = RFBInputEchoUpdateRequester(policy: .keyboard(minimumInterval: 0.05, trigger: .any))
        let transitions = [HIDUsageToX11Keysym.KeyTransition(keysym: 0x61, isDown: true)]
        XCTAssertNil(requester.updateRequestAfterTransitions(transitions, nowUptimeNanoseconds: 1))
        requester.updateFramebufferSize(width: 1920, height: 1080)
        XCTAssertNotNil(requester.updateRequestAfterTransitions(transitions, nowUptimeNanoseconds: 1))
    }

    func test_inputEchoUpdateRequesterTransitionsIgnoresEmptyBatch() {
        let requester = RFBInputEchoUpdateRequester(policy: .keyboard(minimumInterval: 0.05, trigger: .any))
        requester.updateFramebufferSize(width: 1920, height: 1080)
        XCTAssertNil(requester.updateRequestAfterTransitions([], nowUptimeNanoseconds: 1))
    }

    func test_inputEchoUpdateRequesterDisabledPolicyIgnoresTransitions() {
        let requester = RFBInputEchoUpdateRequester(policy: .disabled)
        requester.updateFramebufferSize(width: 1920, height: 1080)
        let transitions = [HIDUsageToX11Keysym.KeyTransition(keysym: 0x61, isDown: true)]
        XCTAssertNil(requester.updateRequestAfterTransitions(transitions, nowUptimeNanoseconds: 1))
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
