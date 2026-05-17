import XCTest
@testable import KVMCore

final class NanoKVMPasswordEncryptorTests: XCTestCase {
    func test_encryptMatchesCryptoJSPassphraseFormatForKnownSalt() throws {
        let encrypted = try NanoKVMPasswordEncryptor.encrypt(
            "admin",
            salt: Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        )

        XCTAssertEqual(
            encrypted,
            "U2FsdGVkX18AAQIDBAUGB7RQW%2Bo4DxJ1XwZq5sFeCig%3D"
        )
    }

    func test_encryptUsesRandomSalt() throws {
        let first = try NanoKVMPasswordEncryptor.encrypt("admin")
        let second = try NanoKVMPasswordEncryptor.encrypt("admin")

        XCTAssertNotEqual(first, second)
    }
}
