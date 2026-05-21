import XCTest
@testable import KVMCore

final class DeviceCodableTests: XCTestCase {
    func test_decodesLegacyJsonWithoutLastConnectedAt() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "Lab",
          "host": "nanokvm.local",
          "port": 80,
          "scheme": "http",
          "username": "admin"
        }
        """

        let device = try JSONDecoder().decode(Device.self, from: Data(json.utf8))

        XCTAssertNil(device.lastConnectedAt)
        XCTAssertEqual(device.kvmType, .nanoKVMUSB)
        XCTAssertEqual(device.name, "Lab")
        XCTAssertEqual(device.host, "nanokvm.local")
    }

    func test_decodesKvmTypeWhenPresent() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "Lab",
          "host": "nanokvm.local",
          "port": 80,
          "scheme": "http",
          "username": "admin",
          "kvmType": "comet"
        }
        """

        let device = try JSONDecoder().decode(Device.self, from: Data(json.utf8))

        XCTAssertEqual(device.kvmType, .comet)
    }

    func test_decodesLegacyAppleRFBAsAppleScreenSharing() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "Mac",
          "host": "mac.local",
          "port": 5900,
          "scheme": "http",
          "username": "yuxi",
          "kvmType": "appleRFB"
        }
        """

        let device = try JSONDecoder().decode(Device.self, from: Data(json.utf8))

        XCTAssertEqual(device.kvmType, .appleScreenSharing)
    }
}
