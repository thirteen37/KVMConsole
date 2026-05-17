import Foundation

@MainActor
public enum KVMSessionFactory {
    public static func make(
        for device: Device,
        passwordStore: PasswordStore,
        renderCoordinator: SampleBufferRenderCoordinator
    ) -> any KVMSession {
        switch device.kind {
        case .nanoKVM:
            return NanoKVMSession(passwordStore: passwordStore, renderCoordinator: renderCoordinator)
        case .glkvm:
            return GLKVMSession(passwordStore: passwordStore, renderCoordinator: renderCoordinator)
        }
    }
}

