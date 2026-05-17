import Foundation

public protocol KVMPowerControl: Sendable {
    func powerOn() async throws
    func powerOff() async throws
    func forceOff() async throws
    func reset() async throws
    func longPressPower() async throws
}

