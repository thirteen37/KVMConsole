import OSLog

enum KVMLog {
    static let glkvm = Logger(subsystem: "com.kvmconsole.app", category: "GLKVM")
    static let rfb = Logger(subsystem: "com.kvmconsole.app", category: "RFB")
    static let video = Logger(subsystem: "com.kvmconsole.app", category: "Video")
}
