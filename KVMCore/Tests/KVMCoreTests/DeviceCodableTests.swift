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
        XCTAssertEqual(device.kvmType, .nanoKVMLite)
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

    func test_decodesLegacyJsonWithoutUSBFields() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "Lab",
          "host": "nanokvm.local",
          "port": 80,
          "scheme": "http",
          "username": "admin",
          "kvmType": "nanoKVMUSB"
        }
        """

        let device = try JSONDecoder().decode(Device.self, from: Data(json.utf8))

        XCTAssertEqual(device.kvmType, .nanoKVMUSB)
        XCTAssertNil(device.videoDeviceUniqueID)
        XCTAssertNil(device.serialDevicePath)
    }

    func test_roundTripsUSBFields() throws {
        let original = Device(
            name: "Bench USB",
            host: "",
            port: 0,
            scheme: .http,
            username: "",
            kvmType: .nanoKVMUSB,
            videoDeviceUniqueID: "0xfd11ce10",
            serialDevicePath: "/dev/cu.usbserial-A50285BI"
        )

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(Device.self, from: data)

        XCTAssertEqual(restored.videoDeviceUniqueID, "0xfd11ce10")
        XCTAssertEqual(restored.serialDevicePath, "/dev/cu.usbserial-A50285BI")
        XCTAssertEqual(restored.kvmType, .nanoKVMUSB)
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
