import XCTest
@testable import KVMCore

final class GLKVMClientTests: XCTestCase {
    func test_loginPostsFormBodyAndStoresAuthCookie() async throws {
        let session = MockURLSession()
        session.enqueue(.init(
            json: "{}",
            headers: ["Set-Cookie": "auth_token=abc123; Path=/; HttpOnly"]
        ))
        let device = Device(name: "Comet", host: "kvm.local", scheme: .https, kvmType: .comet)
        let client = GLKVMClient(device: device, session: session)

        try await client.login(password: "secret")

        let request = try XCTUnwrap(session.sent.first)
        XCTAssertEqual(request.url?.absoluteString, "https://kvm.local/api/auth/login")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded; charset=utf-8")
        XCTAssertEqual(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8), "passwd=secret&user=admin")
        let token = await client.authToken
        XCTAssertEqual(token, "abc123")
    }

    func test_atxResetPostsAuthenticatedAction() async throws {
        let session = MockURLSession()
        session.enqueue(.init(json: "{}"))
        let device = Device(name: "Comet", host: "kvm.local", scheme: .https, kvmType: .comet)
        let client = GLKVMClient(device: device, session: session)
        await client.setAuthToken("token")

        try await client.reset()

        let request = try XCTUnwrap(session.sent.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://kvm.local/api/atx/power?action=reset_hard")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth_token=token")
    }

    func test_setStreamerVideoFormatH264PostsAuthenticatedParams() async throws {
        let session = MockURLSession()
        session.enqueue(.init(json: "{}"))
        let device = Device(name: "Comet", host: "kvm.local", scheme: .https, kvmType: .comet)
        let client = GLKVMClient(device: device, session: session)
        await client.setAuthToken("token")

        try await client.setStreamerVideoFormatH264()

        let request = try XCTUnwrap(session.sent.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://kvm.local/api/streamer/set_params?video_format=0&h264_gop=30")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth_token=token")
    }
}
