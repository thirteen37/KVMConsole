import XCTest
@testable import NanoKVM

final class KeychainPasswordStoreTests: XCTestCase {
    func test_accountNormalizesHostAndUsername() {
        let account = KeychainPasswordAccount(
            scheme: .https,
            host: " NanoKVM.Local ",
            port: 443,
            username: " admin "
        )

        XCTAssertEqual(account.rawValue, "https://nanokvm.local:443#admin")
    }

    func test_keychainStoreRoundTripsPassword() throws {
        let service = "io.lyx.NanoKVMTests.\(UUID().uuidString)"
        let store = KeychainPasswordStore(service: service)
        let account = "http://nanokvm.local:80#admin"

        try store.savePassword("secret", for: account)
        XCTAssertEqual(try store.password(for: account), "secret")

        try store.savePassword("new-secret", for: account)
        XCTAssertEqual(try store.password(for: account), "new-secret")

        try store.deletePassword(for: account)
        XCTAssertNil(try store.password(for: account))
    }
}
