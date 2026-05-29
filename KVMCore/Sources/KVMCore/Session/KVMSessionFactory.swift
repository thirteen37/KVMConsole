import Foundation

@MainActor
public enum KVMSessionFactory {
    public static func make(
        for device: Device,
        passwordStore: PasswordStore,
        renderCoordinator: SampleBufferRenderCoordinator
    ) -> any KVMSession {
        switch device.kvmType {
        case .nanoKVMUSB:
            #if os(macOS)
            return NanoKVMUSBSession(passwordStore: passwordStore, renderCoordinator: renderCoordinator)
            #else
            // iPadOS has no public USB-serial API; .nanoKVMUSB is filtered out of the
            // editor (see Device.KVMType.userVisibleCases) so saved devices can only reach
            // this path if synced from a macOS install. Fall back to the IP-based session
            // — it will surface a connection error rather than crashing.
            return NanoKVMSession(passwordStore: passwordStore, renderCoordinator: renderCoordinator)
            #endif
        case .nanoKVMLite:
            return NanoKVMSession(passwordStore: passwordStore, renderCoordinator: renderCoordinator)
        case .comet:
            return GLKVMSession(passwordStore: passwordStore, renderCoordinator: renderCoordinator)
        case .appleScreenSharing:
            return RFBSession(
                profile: .appleScreenSharing,
                passwordStore: passwordStore,
                renderCoordinator: renderCoordinator
            )
        case .vnc:
            return RFBSession(
                profile: .vnc,
                passwordStore: passwordStore,
                renderCoordinator: renderCoordinator
            )
        }
    }
}
