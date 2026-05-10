import NanoKVMCore
import SwiftUI

@main
struct NanoKVMiPadApp: App {
    @StateObject private var devicesStore = SavedDevicesStore()
    @State private var connectedDeviceID: Device.ID?

    var body: some Scene {
        WindowGroup("NanoKVM") {
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
