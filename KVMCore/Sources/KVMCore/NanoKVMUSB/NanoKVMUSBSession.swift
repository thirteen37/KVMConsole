#if os(macOS)
import CoreGraphics
import Foundation

private final class WeakSession: @unchecked Sendable {
    weak var value: NanoKVMUSBSession?
    init(value: NanoKVMUSBSession?) { self.value = value }
}

public enum NanoKVMUSBError: Error, LocalizedError {
    case missingVideoDevice
    case missingSerialDevice

    public var errorDescription: String? {
        switch self {
        case .missingVideoDevice:
            return "No USB video device has been selected for this NanoKVM USB."
        case .missingSerialDevice:
            return "No USB serial port has been selected for this NanoKVM USB."
        }
    }
}

@MainActor
public final class NanoKVMUSBSession: KVMSession {
    public var onStateChange: ((KVMSessionState) -> Void)?
    public var onVideoSize: ((CGSize?) -> Void)?
    public var onFlush: (() -> Void)?
    public var onHostStatusChange: ((KVMHostStatus?) -> Void)?

    public private(set) var state: KVMSessionState = .disconnected {
        didSet { onStateChange?(state) }
    }

    public var powerControl: KVMPowerControl? { nil }
    public var hostStatus: KVMHostStatus? { nil }
    public var isStreaming: Bool { state == .streaming }

    private let renderCoordinator: SampleBufferRenderCoordinator
    private var captureSource: UVCCaptureSource?
    private var serialTransport: CH9329SerialTransport?
    private var mouseMoveCoalescer: MouseMoveCoalescer?
    private var generation: Int = 0

    public init(
        passwordStore: PasswordStore = KeychainPasswordStore(),
        renderCoordinator: SampleBufferRenderCoordinator = SampleBufferRenderCoordinator()
    ) {
        // NanoKVM USB has no auth; the password store is accepted for API symmetry but unused.
        _ = passwordStore
        self.renderCoordinator = renderCoordinator
    }

    public func connect(_ configuration: KVMSessionConfiguration) {
        disconnect(updateState: false)
        generation &+= 1
        let myGeneration = generation
        state = .connecting

        guard let videoID = configuration.device.videoDeviceUniqueID, !videoID.isEmpty else {
            finishWithError(NanoKVMUSBError.missingVideoDevice)
            return
        }
        guard let serialPath = configuration.device.serialDevicePath, !serialPath.isEmpty else {
            finishWithError(NanoKVMUSBError.missingSerialDevice)
            return
        }

        let capture = UVCCaptureSource(renderCoordinator: renderCoordinator)
        capture.onVideoSize = { [weak self] size in
            guard let self, self.generation == myGeneration else { return }
            self.onVideoSize?(size)
        }
        capture.onRuntimeError = { [weak self] error in
            guard let self, self.generation == myGeneration else { return }
            guard self.state == .connecting || self.state == .streaming else { return }
            self.finishWithError(error)
        }

        do {
            try capture.start(deviceUniqueID: videoID)
        } catch {
            finishWithError(error)
            return
        }

        let transport = CH9329SerialTransport(devicePath: serialPath)
        captureSource = capture
        serialTransport = transport
        mouseMoveCoalescer = MouseMoveCoalescer { [weak transport] report in
            guard let transport else { return }
            let packet = CH9329Protocol.absoluteMousePacket(report)
            do {
                try await transport.send(packet)
            } catch {
                KVMLog.video.error(
                    "CH9329 mouse send failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        Task { [weak self] in
            do {
                try await transport.open()
                let weakSelfBox = WeakSession(value: self)
                await transport.setOnDisconnect { error in
                    Task { @MainActor in
                        guard let session = weakSelfBox.value, session.generation == myGeneration else { return }
                        guard session.state == .connecting || session.state == .streaming else { return }
                        session.finishWithError(error ?? CH9329SerialError.closed)
                    }
                }
                await MainActor.run {
                    guard let self, self.generation == myGeneration else { return }
                    guard self.state == .connecting else { return }
                    self.state = .streaming
                }
            } catch {
                await MainActor.run {
                    guard let self, self.generation == myGeneration else { return }
                    self.finishWithError(error)
                }
            }
        }
    }

    public func disconnect(updateState: Bool = true) {
        generation &+= 1
        captureSource?.stop()
        captureSource = nil

        let transport = serialTransport
        serialTransport = nil
        let coalescer = mouseMoveCoalescer
        mouseMoveCoalescer = nil
        Task {
            await coalescer?.cancel()
            await transport?.close()
        }

        if updateState {
            state = .disconnected
        }
        onFlush?()
    }

    public func sendKeyboardReport(_ report: HIDKeyboardReport) {
        guard let transport = serialTransport else { return }
        let packet = CH9329Protocol.keyboardPacket(report)
        Task(priority: .userInitiated) {
            do {
                try await transport.send(packet)
            } catch {
                KVMLog.video.error(
                    "CH9329 keyboard send failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    public func sendMouseReport(_ report: HIDMouseAbsoluteReport) {
        guard let coalescer = mouseMoveCoalescer else { return }
        Task(priority: .userInitiated) {
            await coalescer.enqueue(report)
        }
    }

    private func finishWithError(_ error: Error) {
        captureSource?.stop()
        captureSource = nil

        let transport = serialTransport
        serialTransport = nil
        let coalescer = mouseMoveCoalescer
        mouseMoveCoalescer = nil
        Task {
            await coalescer?.cancel()
            await transport?.close()
        }

        state = .error(error.localizedDescription)
        onFlush?()
    }
}
#endif
