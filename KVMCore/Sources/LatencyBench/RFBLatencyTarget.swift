#if os(macOS)
@preconcurrency import CoreMedia
import CoreGraphics
import Foundation
import KVMCore

/// Latency target that drives a live `RFBClient` directly. We use the client
/// rather than the full `RFBSession` so we can intercept sample buffers via
/// the existing `onSampleBuffer` callback without subclassing the render
/// coordinator.
@MainActor
final class RFBLatencyTarget: LatencyTarget {
    let displayLabel: String
    let sampleBuffers: AsyncStream<CMSampleBuffer>

    private let device: Device
    private let profile: RFBSessionProfile
    private let password: String
    private let sampleBufferContinuation: AsyncStream<CMSampleBuffer>.Continuation
    private let videoSizeBox = ValueBox<CGSize>()
    private var client: RFBClient?
    private var runTask: Task<Void, Error>?

    init(device: Device, password: String) {
        self.device = device
        self.password = password
        self.displayLabel = "\(device.name) (\(device.kvmType.displayName))"
        switch device.kvmType {
        case .appleScreenSharing:
            self.profile = .appleScreenSharing
        case .vnc:
            self.profile = .vnc
        default:
            self.profile = .vnc
        }

        var continuation: AsyncStream<CMSampleBuffer>.Continuation!
        self.sampleBuffers = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.sampleBufferContinuation = continuation
    }

    var framebufferSize: CGSize? {
        get async { await videoSizeBox.value }
    }

    func connect() async throws {
        let continuation = sampleBufferContinuation
        let videoSizeBox = videoSizeBox

        let client = RFBClient(
            device: device,
            profile: profile,
            onSampleBuffer: { sample in
                continuation.yield(sample)
            },
            onVideoSize: { size in
                Task { await videoSizeBox.set(size) }
            },
            onAuthenticated: {}
        )
        self.client = client

        let password = password
        let task = Task<Void, Error> {
            do {
                try await client.connectAndRun(password: password)
                continuation.finish()
            } catch {
                continuation.finish()
                throw error
            }
        }
        self.runTask = task

        // Wait for first video-size (signals streaming started).
        let deadline = Date().addingTimeInterval(30)
        while await videoSizeBox.value == nil {
            if Date() > deadline {
                task.cancel()
                throw RFBLatencyTargetError.connectTimedOut(host: device.host, port: device.port)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            if task.isCancelled { throw CancellationError() }
        }
    }

    func disconnect() async {
        sampleBufferContinuation.finish()
        runTask?.cancel()
        if let client {
            await client.close()
        }
        client = nil
        runTask = nil
    }

    func sendMouseReport(_ report: HIDMouseAbsoluteReport) async {
        guard let client else { return }
        await client.sendMouseReport(report)
    }

    func sendKeyboardReport(_ report: HIDKeyboardReport) async {
        guard let client else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            client.sendKeyboardReport(report) {
                continuation.resume()
            }
        }
    }
}

enum RFBLatencyTargetError: Error, LocalizedError {
    case connectTimedOut(host: String, port: Int)

    var errorDescription: String? {
        switch self {
        case .connectTimedOut(let host, let port):
            return "Timed out waiting for RFB framebuffer size announcement from \(host):\(port). Apple Screen Sharing usually listens on port 5900."
        }
    }
}

actor ValueBox<Value: Sendable> {
    private var stored: Value?

    var value: Value? { stored }

    func set(_ value: Value) {
        stored = value
    }
}
#endif
