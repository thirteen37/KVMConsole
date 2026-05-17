import KVMCore
import SwiftUI

@main
struct KVMConsoleApp: App {
    @StateObject private var devicesStore = SavedDevicesStore()

    var body: some Scene {
        Window("Connections", id: "connections") {
            NavigationStack {
                ConnectionManagerView()
            }
            .frame(minWidth: 560, minHeight: 360)
            .environmentObject(devicesStore)
        }
        .windowResizability(.contentSize)

        WindowGroup("Viewer", id: "viewer", for: Device.ID.self) { $deviceID in
            ViewerHostView(deviceID: deviceID)
                .environmentObject(devicesStore)
        }
        .windowResizability(.contentMinSize)
    }
}
