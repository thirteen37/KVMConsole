import XCTest
@testable import KVMCore

final class JanusMessageTests: XCTestCase {
    func test_decodesSessionAndHandleIDs() throws {
        let json = Data(#"{"janus":"success","transaction":"t1","session_id":7,"sender":9,"data":{"id":11}}"#.utf8)
        let response = try JSONDecoder().decode(JanusResponse.self, from: json)
        XCTAssertEqual(response.janus, "success")
        XCTAssertEqual(response.transaction, "t1")
        XCTAssertEqual(response.sessionID, 7)
        XCTAssertEqual(response.sender, 9)
        XCTAssertEqual(response.data?.id, 11)
    }

    func test_keyRequiredMessageUsesUStreamerRequestShape() throws {
        let payload = JanusMessage.keyRequired(sessionID: 7, handleID: 11, transaction: "t1")

        XCTAssertEqual(payload["janus"] as? String, "message")
        XCTAssertEqual(payload["session_id"] as? Int64, 7)
        XCTAssertEqual(payload["handle_id"] as? Int64, 11)
        XCTAssertEqual(payload["transaction"] as? String, "t1")

        let body = try XCTUnwrap(payload["body"] as? [String: Any])
        XCTAssertEqual(body["request"] as? String, "key_required")
    }

    func test_watchMessageRequestsWebRTCVideo() throws {
        let payload = JanusMessage.watch(sessionID: 7, handleID: 11, transaction: "t1")
        let body = try XCTUnwrap(payload["body"] as? [String: Any])
        let params = try XCTUnwrap(body["params"] as? [String: Any])

        XCTAssertEqual(body["request"] as? String, "watch")
        XCTAssertEqual(params["audio"] as? Bool, false)
        XCTAssertEqual(params["video"] as? Bool, true)
        XCTAssertEqual(params["mic"] as? Bool, false)
        XCTAssertEqual(params["camera"] as? Bool, false)
        XCTAssertEqual(params["video_format"] as? Int, 0)
    }
}
