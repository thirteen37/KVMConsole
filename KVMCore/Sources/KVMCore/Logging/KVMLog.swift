import OSLog

enum KVMLog {
    static let glkvm = Logger(subsystem: "com.kvmconsole.app", category: "GLKVM")
    static let webrtc = Logger(subsystem: "com.kvmconsole.app", category: "WebRTC")
}
