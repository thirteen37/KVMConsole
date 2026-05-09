import XCTest
@testable import NanoKVMCore

@MainActor
final class SavedDevicesStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedDevicesStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        super.tearDown()
    }

    func test_addPersistsAcrossInstances() {
        let url = storeURL()
        let passwordStore = InMemoryPasswordStore()
        let device = makeDevice(name: "Lab")

        let first = SavedDevicesStore(storeURL: url, passwordStore: passwordStore)
        first.add(device)

        let second = SavedDevicesStore(storeURL: url, passwordStore: passwordStore)
        XCTAssertEqual(second.devices, [device])
    }

    func test_updateMutatesInPlace() {
        let store = SavedDevicesStore(storeURL: storeURL(), passwordStore: InMemoryPasswordStore())
        var device = makeDevice(name: "Lab")
        store.add(device)

        device.name = "Workshop"
        store.update(device)

        XCTAssertEqual(store.devices.count, 1)
        XCTAssertEqual(store.devices.first?.name, "Workshop")
    }

    func test_deleteRemovesDeviceAndKeychainPassword() throws {
        let passwordStore = InMemoryPasswordStore()
        let store = SavedDevicesStore(storeURL: storeURL(), passwordStore: passwordStore)
        let device = makeDevice(name: "Lab")
        store.add(device)
        let account = store.keychainAccount(for: device)
        try passwordStore.savePassword("hunter2", for: account)

        store.delete(device)

        XCTAssertTrue(store.devices.isEmpty)
        XCTAssertNil(try passwordStore.password(for: account))
    }

    func test_updateMigratesPasswordWhenAccountChanges() throws {
        let passwordStore = InMemoryPasswordStore()
        let store = SavedDevicesStore(storeURL: storeURL(), passwordStore: passwordStore)
        var device = makeDevice(name: "Lab", username: "admin")
        store.add(device)
        let oldAccount = store.keychainAccount(for: device)
        try passwordStore.savePassword("hunter2", for: oldAccount)

        device.username = "operator"
        store.update(device)
        let newAccount = store.keychainAccount(for: device)

        XCTAssertNotEqual(oldAccount, newAccount)
        XCTAssertEqual(try passwordStore.password(for: newAccount), "hunter2")
        XCTAssertNil(try passwordStore.password(for: oldAccount))
    }

    private func storeURL() -> URL {
        tempDirectory.appendingPathComponent("devices.json")
    }

    private func makeDevice(name: String, username: String = "admin") -> Device {
        Device(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: name,
            host: "nanokvm.local",
            port: 80,
            scheme: .http,
            username: username
        )
    }
}

final class InMemoryPasswordStore: PasswordStore, @unchecked Sendable {
    private var passwords: [String: String] = [:]
    private let lock = NSLock()

    func password(for account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return passwords[account]
    }

    func savePassword(_ password: String, for account: String) throws {
        lock.lock(); defer { lock.unlock() }
        passwords[account] = password
    }

    func deletePassword(for account: String) throws {
        lock.lock(); defer { lock.unlock() }
        passwords.removeValue(forKey: account)
    }
}
