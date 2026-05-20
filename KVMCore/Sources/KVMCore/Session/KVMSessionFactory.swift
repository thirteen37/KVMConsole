import Foundation

@MainActor
public enum KVMSessionFactory {
    public static func make(
        for device: Device,
        passwordStore: PasswordStore,
        renderCoordinator: SampleBufferRenderCoordinator
    ) -> any KVMSession {
        switch device.kvmType {
        case .nanoKVMLite, .nanoKVMUSB:
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
