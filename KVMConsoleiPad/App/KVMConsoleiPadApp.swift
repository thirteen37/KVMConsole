import KVMCore
import SwiftUI

@main
struct KVMConsoleiPadApp: App {
    @StateObject private var devicesStore = SavedDevicesStore()
    @State private var connectedDeviceID: Device.ID?

    var body: some Scene {
        WindowGroup("KVM Console") {
            NavigationStack {
                ConnectionManagerView { device in
                    connectedDeviceID = device.id
                }
                .environmentObject(devicesStore)
                .navigationDestination(item: $connectedDeviceID) { deviceID in
                    ViewerHostView(deviceID: deviceID)
                        .environmentObject(devicesStore)
                }
            }
        }
    }
}
