import NanoKVMCore
import SwiftUI

@main
struct NanoKVMApp: App {
    @StateObject private var devicesStore = SavedDevicesStore()

    var body: some Scene {
        Window("NanoKVM Connections", id: "connections") {
            ConnectionManagerView()
                .environmentObject(devicesStore)
        }
        .windowResizability(.contentSize)

        WindowGroup("NanoKVM", id: "viewer", for: Device.ID.self) { $deviceID in
            ViewerHostView(deviceID: deviceID)
                .environmentObject(devicesStore)
        }
        .windowResizability(.contentMinSize)
    }
}
