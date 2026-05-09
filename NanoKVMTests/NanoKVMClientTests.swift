import XCTest
@testable import NanoKVM

final class NanoKVMClientTests: XCTestCase {
    private func makeClient(_ session: MockURLSession = MockURLSession()) -> (NanoKVMClient, MockURLSession) {
        let device = Device(name: "test", host: "nanokvm.local")
        return (NanoKVMClient(device: device, session: session), session)
    }

    // MARK: login

    func test_login_storesTokenOnSuccess() async throws {
        let session = MockURLSession()
        session.enqueue(.init(json: #"{"code":0,"msg":"success","data":{"token":"jwt.abc.def"}}"#))
        let (client, _) = makeClient(session)
        try await client.login(password: "secret")
        let token = await client.token
        XCTAssertEqual(token, "jwt.abc.def")
    }

    func test_login_sendsLowercaseJSONBodyWithEncryptedPasswordToCorrectURL() async throws {
        let session = MockURLSession()
        session.enqueue(.init(json: #"{"code":0,"msg":"ok","data":{"token":"x"}}"#))
        let (client, _) = makeClient(session)
        try await client.login(password: "p@ss")
        let req = session.sent[0]
        XCTAssertEqual(req.url?.absoluteString, "http://nanokvm.local/api/auth/login")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"), "login must not include auth header")
        let body = try XCTUnwrap(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["username"] as? String, "admin")
        let encryptedPassword = try XCTUnwrap(json?["password"] as? String)
        XCTAssertNotEqual(encryptedPassword, "p@ss")
        XCTAssertTrue(encryptedPassword.hasPrefix("U2FsdGVkX1"), "CryptoJS/OpenSSL salted ciphertext should start with `Salted__` in base64")
        XCTAssertTrue(encryptedPassword.contains("%"), "Ciphertext should be encodeURIComponent-compatible")
    }

    func test_login_throwsOnServerErrorEnvelope() async throws {
        let session = MockURLSession()
        session.enqueue(.init(json: #"{"code":-2,"msg":"invalid username or password","data":null}"#))
        let (client, _) = makeClient(session)
        do {
            try await client.login(password: "wrong")
            XCTFail("expected error")
        } catch let NanoKVMError.serverError(code, message) {
            XCTAssertEqual(code, -2)
            XCTAssertEqual(message, "invalid username or password")
        }
    }

    // MARK: vmInfo

    func test_vmInfo_decodesEnvelopeAndIPArray() async throws {
        let session = MockURLSession()
        session.enqueue(.init(json: #"""
        {"code":0,"msg":"success","data":{
          "ips":[
            {"name":"eth0","addr":"192.168.1.42","version":"ipv4","type":"ethernet"},
            {"name":"eth0","addr":"fe80::1","version":"ipv6","type":"ethernet"}
          ],
          "mdns":"nanokvm-1234.local",
          "image":"latest",
          "application":"3.0.0",
          "deviceKey":"abc"
        }}
        """#))
        let (client, _) = makeClient(session)
        try await client.setToken("token")
        let info = try await client.vmInfo()
        XCTAssertEqual(info.ips.count, 2)
        XCTAssertEqual(info.ips[0].addr, "192.168.1.42")
        XCTAssertEqual(info.mdns, "nanokvm-1234.local")
        XCTAssertEqual(info.application, "3.0.0")
    }

    func test_vmInfo_sendsBearerAndCookie() async throws {
        let session = MockURLSession()
        session.enqueue(.init(json: #"{"code":0,"msg":"","data":{"ips":[],"mdns":"","image":null,"application":null,"deviceKey":null}}"#))
        let (client, _) = makeClient(session)
        try await client.setToken("tk")
        _ = try await client.vmInfo()
        let req = session.sent[0]
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.absoluteString, "http://nanokvm.local/api/vm/info")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tk")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Cookie"), "nano-kvm-token=tk")
    }

    func test_vmInfo_failsWithoutToken() async throws {
        let (client, _) = makeClient()
        do {
            _ = try await client.vmInfo()
            XCTFail("expected missing token")
        } catch NanoKVMError.missingToken {
            // OK
        }
    }

    // MARK: selectH264

    func test_selectH264_postsTypeAndValue() async throws {
        let session = MockURLSession()
        session.enqueue(.init(json: #"{"code":0,"msg":"success"}"#))
        let (client, _) = makeClient(session)
        try await client.setToken("tk")
        try await client.selectH264()
        let req = session.sent[0]
        XCTAssertEqual(req.url?.absoluteString, "http://nanokvm.local/api/vm/screen")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any]
        XCTAssertEqual(body?["type"] as? String, "type")
        XCTAssertEqual(body?["value"] as? Int, 1)
    }

    // MARK: paste

    func test_paste_sendsContentAndLangue() async throws {
        let session = MockURLSession()
        session.enqueue(.init(json: #"{"code":0,"msg":"success"}"#))
        let (client, _) = makeClient(session)
        try await client.setToken("tk")
        try await client.paste("hello", language: "en")
        let body = try JSONSerialization.jsonObject(with: session.sent[0].httpBody!) as? [String: Any]
        XCTAssertEqual(body?["content"] as? String, "hello")
        XCTAssertEqual(body?["langue"] as? String, "en")
    }

    // MARK: HTTP layer

    func test_unexpectedHTTPStatusBecomesError() async throws {
        let session = MockURLSession()
        session.enqueue(.init(status: 500, json: "internal"))
        let (client, _) = makeClient(session)
        do {
            try await client.login(password: "x")
            XCTFail("expected error")
        } catch NanoKVMError.unexpectedStatus(500) {
            // OK
        }
    }
}

final class DeviceTests: XCTestCase {
    func test_baseURL_omitsDefaultPorts() {
        XCTAssertEqual(Device(name: "a", host: "h").baseURL?.absoluteString, "http://h")
        XCTAssertEqual(Device(name: "a", host: "h", scheme: .https).baseURL?.absoluteString, "https://h")
    }

    func test_baseURL_includesNonDefaultPort() {
        XCTAssertEqual(Device(name: "a", host: "h", port: 8080).baseURL?.absoluteString, "http://h:8080")
    }

    func test_baseURL_isNilForInvalidHost() {
        XCTAssertNil(Device(name: "a", host: "host with spaces").baseURL)
    }

    func test_webSocketScheme_followsHTTPScheme() {
        XCTAssertEqual(Device(name: "a", host: "h").webSocketScheme, "ws")
        XCTAssertEqual(Device(name: "a", host: "h", scheme: .https).webSocketScheme, "wss")
    }
}
