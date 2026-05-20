import CoreGraphics
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation

@MainActor
public final class RFBSession: KVMSession {
    public var onStateChange: ((KVMSessionState) -> Void)?
    public var onVideoSize: ((CGSize?) -> Void)?
    public var onFlush: (() -> Void)?

    public private(set) var state: KVMSessionState = .disconnected {
        didSet {
            onStateChange?(state)
        }
    }

    private let profile: RFBSessionProfile
    private let passwordStore: PasswordStore
    private let renderCoordinator: SampleBufferRenderCoordinator
    private var client: RFBClient?
    private var mouseMoveCoalescer: MouseMoveCoalescer?
    private var streamTask: Task<Void, Never>?
    private var generation: Int = 0

    public init(
        profile: RFBSessionProfile,
        passwordStore: PasswordStore = KeychainPasswordStore(),
        renderCoordinator: SampleBufferRenderCoordinator = SampleBufferRenderCoordinator()
    ) {
        self.profile = profile
        self.passwordStore = passwordStore
        self.renderCoordinator = renderCoordinator
    }

    public var isStreaming: Bool {
        streamTask != nil
    }

    public var powerControl: KVMPowerControl? { nil }

    public func connect(_ configuration: KVMSessionConfiguration) {
        disconnect(updateState: false)
        generation &+= 1
        let myGeneration = generation
        state = .connecting

        let client = RFBClient(
            device: configuration.device,
            profile: profile,
            onSampleBuffer: { [renderCoordinator] sampleBuffer in
                renderCoordinator.enqueue(sampleBuffer)
            },
            onVideoSize: { [weak self] videoSize in
                Task { @MainActor in
                    guard let self, self.generation == myGeneration else { return }
                    self.onVideoSize?(videoSize)
                    if self.state == .connecting {
                        self.state = .streaming
                    }
                }
            },
            onAuthenticated: { [passwordStore] in
                try? passwordStore.savePassword(configuration.password, for: configuration.passwordAccount)
            }
        )
        let mouseMoveCoalescer = MouseMoveCoalescer { report in
            await client.sendMouseReport(report)
        }
        self.client = client
        self.mouseMoveCoalescer = mouseMoveCoalescer

        streamTask = Task { [weak self] in
            do {
                try await client.connectAndRun(password: configuration.password)
                await MainActor.run {
                    guard let self, self.generation == myGeneration else { return }
                    self.finishDisconnected()
                }
            } catch {
                let isCancellation = error is CancellationError
                    || (error as? URLError)?.code == .cancelled
                await MainActor.run {
                    guard let self, self.generation == myGeneration else { return }
                    if isCancellation {
                        self.clearResources(cancelTask: false)
                    } else {
                        self.finishWithError(error)
                    }
                }
            }
        }
    }

    public func disconnect(updateState: Bool = true) {
        clearResources(cancelTask: true)
        if updateState {
            state = .disconnected
        }
        onFlush?()
    }

    public func sendKeyboardReport(_ report: HIDKeyboardReport) {
        guard let client else { return }
        Task(priority: .userInitiated) {
            await client.sendKeyboardReport(report)
        }
    }

    public func sendMouseReport(_ report: HIDMouseAbsoluteReport) {
        guard let mouseMoveCoalescer else { return }
        Task(priority: .userInitiated) {
            await mouseMoveCoalescer.enqueue(report)
        }
    }

    private func finishDisconnected() {
        clearResources(cancelTask: false)
        state = .disconnected
        onFlush?()
    }

    private func finishWithError(_ error: Error) {
        KVMLog.rfb.error("RFB session failed: \(error.localizedDescription, privacy: .public)")
        clearResources(cancelTask: false)
        state = .error(error.localizedDescription)
        onFlush?()
    }

    private func clearResources(cancelTask: Bool) {
        if cancelTask {
            streamTask?.cancel()
        }
        streamTask = nil

        let client = client
        self.client = nil
        let mouseMoveCoalescer = mouseMoveCoalescer
        self.mouseMoveCoalescer = nil
        Task {
            await mouseMoveCoalescer?.cancel()
            await client?.close()
        }
    }
}
