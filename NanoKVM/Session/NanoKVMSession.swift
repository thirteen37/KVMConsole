import CoreGraphics
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation

struct NanoKVMSessionConfiguration: Equatable {
    let device: Device
    let password: String
    let passwordAccount: String
}

enum NanoKVMSessionState: Equatable {
    case disconnected
    case connecting
    case streaming
    case error(String)

    var displayText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .streaming: return "Streaming"
        case .error: return "Error"
        }
    }

    var errorMessage: String? {
        if case .error(let message) = self {
            return message
        }
        return nil
    }
}

@MainActor
final class NanoKVMSession {
    var onStateChange: ((NanoKVMSessionState) -> Void)?
    var onSampleBuffer: ((CMSampleBuffer, CGSize?) -> Void)?
    var onFlush: (() -> Void)?

    private(set) var state: NanoKVMSessionState = .disconnected {
        didSet {
            onStateChange?(state)
        }
    }

    private var client: NanoKVMClient?
    private var videoSocket: H264StreamSocket?
    private var controlSocket: ControlSocket?
    private var decoder: H264Decoder?
    private var streamTask: Task<Void, Never>?
    private var generation: Int = 0
    private let passwordStore: PasswordStore

    init(passwordStore: PasswordStore = KeychainPasswordStore()) {
        self.passwordStore = passwordStore
    }

    var isStreaming: Bool {
        streamTask != nil
    }

    func connect(_ configuration: NanoKVMSessionConfiguration) {
        disconnect(updateState: false)
        generation &+= 1
        let myGeneration = generation
        state = .connecting

        let client = NanoKVMClient(device: configuration.device)
        let decoder = H264Decoder { [weak self] sampleBuffer in
            self?.onSampleBuffer?(sampleBuffer, Self.videoSize(from: sampleBuffer))
        }
        self.client = client
        self.decoder = decoder

        streamTask = Task { [weak self] in
            var localControlSocket: ControlSocket?
            var localVideoSocket: H264StreamSocket?
            var handedOff = false

            do {
                try await client.login(password: configuration.password)
                try Task.checkCancellation()
                try? self?.passwordStore.savePassword(configuration.password, for: configuration.passwordAccount)
                try await client.selectH264()
                try Task.checkCancellation()

                guard let token = await client.token else {
                    throw NanoKVMError.missingToken
                }

                let controlSocket = ControlSocket(device: configuration.device, token: token)
                try await controlSocket.connect()
                await controlSocket.setOnDisconnect { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.generation == myGeneration else { return }
                        self.finishWithError(error)
                    }
                }
                localControlSocket = controlSocket

                let videoSocket = H264StreamSocket(device: configuration.device, token: token)
                let frames = try videoSocket.frames()
                localVideoSocket = videoSocket

                handedOff = await MainActor.run { () -> Bool in
                    guard let self, self.generation == myGeneration else { return false }
                    self.controlSocket = controlSocket
                    self.videoSocket = videoSocket
                    self.state = .streaming
                    return true
                }

                guard handedOff else {
                    videoSocket.cancel()
                    await controlSocket.close()
                    return
                }

                for try await frame in frames {
                    try Task.checkCancellation()
                    try decoder.decode(frame)
                }

                await MainActor.run {
                    guard let self, self.generation == myGeneration else { return }
                    self.finishDisconnected()
                }
            } catch {
                if !handedOff {
                    localVideoSocket?.cancel()
                    if let socket = localControlSocket {
                        await socket.close()
                    }
                }
                let isCancellation = (error is CancellationError)
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

    func disconnect(updateState: Bool = true) {
        clearResources(cancelTask: true)
        if updateState {
            state = .disconnected
        }
        onFlush?()
    }

    func sendKeyboardReport(_ report: HIDKeyboardReport) {
        guard let controlSocket else { return }
        Task {
            await controlSocket.sendKeyboardReport(report)
        }
    }

    func sendMouseReport(_ report: HIDMouseAbsoluteReport) {
        guard let controlSocket else { return }
        Task {
            await controlSocket.sendMouseAbsoluteReport(report)
        }
    }

    private func finishDisconnected() {
        clearResources(cancelTask: false)
        state = .disconnected
        onFlush?()
    }

    private func finishWithError(_ error: Error) {
        clearResources(cancelTask: false)
        state = .error(error.localizedDescription)
        onFlush?()
    }

    private func clearResources(cancelTask: Bool) {
        if cancelTask {
            streamTask?.cancel()
        }
        streamTask = nil
        videoSocket?.cancel()
        videoSocket = nil

        let controlSocket = controlSocket
        self.controlSocket = nil
        Task {
            await controlSocket?.close()
        }

        decoder?.invalidate()
        decoder = nil
        client = nil
    }

    private static func videoSize(from sampleBuffer: CMSampleBuffer) -> CGSize? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        return CGSize(
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer)
        )
    }
}
