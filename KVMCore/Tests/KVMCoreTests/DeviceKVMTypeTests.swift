import XCTest
@testable import KVMCore

final class DeviceKVMTypeTests: XCTestCase {
    func test_requiresPasswordAuthentication_isFalseForUSBOnly() {
        XCTAssertFalse(Device.KVMType.nanoKVMUSB.requiresPasswordAuthentication)
        XCTAssertTrue(Device.KVMType.nanoKVMLite.requiresPasswordAuthentication)
        XCTAssertTrue(Device.KVMType.comet.requiresPasswordAuthentication)
        XCTAssertTrue(Device.KVMType.appleScreenSharing.requiresPasswordAuthentication)
        XCTAssertTrue(Device.KVMType.vnc.requiresPasswordAuthentication)
    }

    func test_iconBadgeSymbol_distinguishesLiteAndUSB() {
        XCTAssertEqual(Device.KVMType.nanoKVMLite.iconBadgeSymbol, "network")
        XCTAssertEqual(Device.KVMType.nanoKVMUSB.iconBadgeSymbol, "cable.connector")
        XCTAssertNil(Device.KVMType.comet.iconBadgeSymbol)
        XCTAssertNil(Device.KVMType.appleScreenSharing.iconBadgeSymbol)
        XCTAssertNil(Device.KVMType.vnc.iconBadgeSymbol)
    }
}
