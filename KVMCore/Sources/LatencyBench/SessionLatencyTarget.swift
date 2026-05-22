#if os(macOS)
@preconcurrency import CoreMedia
import CoreGraphics
import Foundation
import KVMCore

/// Shared adapter for any `KVMSession` that exposes a render coordinator.
/// The bench installs a sample observer on the coordinator so it can tap
/// decoded sample buffers without touching the production render pipeline.
///
/// This is used by `NanoKVMLatencyTarget` and `GLKVMLatencyTarget`. RFB has
/// its own adapter that uses `RFBClient` directly because the session
/// wraps the client unnecessarily for a measurement run.
@MainActor
final class SessionLatencyTarget: LatencyTarget {
    let displayLabel: String
    let sampleBuffers: AsyncStream<CMSampleBuffer>

    private let session: any KVMSession
    private let configuration: KVMSessionConfiguration
    private let renderCoordinator: SampleBufferRenderCoordinator
    private let continuation: AsyncStream<CMSampleBuffer>.Continuation
    private let videoSizeBox = ValueBox<CGSize>()

    init(
        displayLabel: String,
        session: any KVMSession,
        configuration: KVMSessionConfiguration,
        renderCoordinator: SampleBufferRenderCoordinator
    ) {
        self.displayLabel = displayLabel
        self.session = session
        self.configuration = configuration
        self.renderCoordinator = renderCoordinator

        var c: AsyncStream<CMSampleBuffer>.Continuation!
        self.sampleBuffers = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        self.continuation = c
    }

    var framebufferSize: CGSize? {
        get async { await videoSizeBox.value }
    }

    func connect() async throws {
        let continuation = continuation
        renderCoordinator.setSampleObserver { sample in
            continuation.yield(sample)
        }

        let videoSizeBox = videoSizeBox
        session.onVideoSize = { size in
            guard let size else { return }
            Task { await videoSizeBox.set(size) }
        }

        let errorBox = AsyncErrorBox()
        let stateGate = AsyncSignal()
        session.onStateChange = { state in
            switch state {
            case .streaming:
                stateGate.signal()
            case .error(let message):
                errorBox.set(SessionLatencyTargetError.sessionError(message))
                stateGate.signal()
            case .disconnected:
                continuation.finish()
            default: break
            }
        }

        session.connect(configuration)
        await stateGate.wait()
        if let error = errorBox.get() { throw error }
    }

    func disconnect() async {
        renderCoordinator.setSampleObserver(nil)
        continuation.finish()
        session.disconnect(updateState: true)
    }

    func sendKeyboardReport(_ report: HIDKeyboardReport) async {
        session.sendKeyboardReport(report)
    }

    func sendMouseReport(_ report: HIDMouseAbsoluteReport) async {
        session.sendMouseReport(report)
    }
}

enum SessionLatencyTargetError: Error, LocalizedError {
    case sessionError(String)

    var errorDescription: String? {
        switch self {
        case .sessionError(let message): return "Session error: \(message)"
        }
    }
}

final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func signal() {
        lock.lock()
        signalled = true
        let waiters = continuations
        continuations.removeAll()
        lock.unlock()
        for c in waiters { c.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if signalled {
                lock.unlock()
                continuation.resume()
                return
            }
            continuations.append(continuation)
            lock.unlock()
        }
    }
}

final class AsyncErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func set(_ error: Error) {
        lock.lock()
        if self.error == nil { self.error = error }
        lock.unlock()
    }

    func get() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}

@MainActor
enum NanoKVMLatencyTarget {
    static func make(device: Device, password: String, account: String) -> SessionLatencyTarget {
        let coordinator = SampleBufferRenderCoordinator()
        let session = NanoKVMSession(renderCoordinator: coordinator)
        let configuration = KVMSessionConfiguration(
            device: device,
            password: password,
            passwordAccount: account
        )
        return SessionLatencyTarget(
            displayLabel: "\(device.name) (\(device.kvmType.displayName))",
            session: session,
            configuration: configuration,
            renderCoordinator: coordinator
        )
    }
}

@MainActor
enum GLKVMLatencyTarget {
    static func make(device: Device, password: String, account: String) -> SessionLatencyTarget {
        let coordinator = SampleBufferRenderCoordinator()
        let session = GLKVMSession(renderCoordinator: coordinator)
        let configuration = KVMSessionConfiguration(
            device: device,
            password: password,
            passwordAccount: account
        )
        return SessionLatencyTarget(
            displayLabel: "\(device.name) (\(device.kvmType.displayName))",
            session: session,
            configuration: configuration,
            renderCoordinator: coordinator
        )
    }
}
#endif
