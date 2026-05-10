import Foundation
@preconcurrency import CoreMedia

@MainActor
public final class ViewerViewModel: ObservableObject {
    @Published public var device: Device
    @Published public var status: String
    @Published public var errorMessage: String?
    @Published public var latestSampleBuffer: CMSampleBuffer?
    @Published public var videoSize: CGSize?
    @Published public var flushToken = 0
    @Published public var isKeyboardCaptureEnabled = true
    @Published public var isMouseCaptureEnabled = true
    @Published public var isScrollInverted = true
    @Published public var passwordPrompt: String?
    @Published public var passwordInput: String = ""
    @Published public var isFullscreen: Bool = false
    @Published public var showFullscreenBanner: Bool = false

    public var toggleFullscreen: (() -> Void)?

    private let session: NanoKVMSession
    private let passwordStore: PasswordStore
    private var bannerTask: Task<Void, Never>?

    public init(device: Device, passwordStore: PasswordStore = KeychainPasswordStore()) {
        self.device = device
        self.passwordStore = passwordStore
        self.session = NanoKVMSession(passwordStore: passwordStore)
        self.status = NanoKVMSessionState.disconnected.displayText

        session.onStateChange = { [weak self] state in
            self?.status = state.displayText
            self?.errorMessage = state.errorMessage
        }
        session.onSampleBuffer = { [weak self] sampleBuffer, videoSize in
            guard let self else { return }
            if self.videoSize != videoSize {
                self.videoSize = videoSize
            }
            self.latestSampleBuffer = sampleBuffer
        }
        session.onFlush = { [weak self] in
            self?.flushVideo()
        }

        attemptAutoConnect()
    }

    public var isStreaming: Bool { session.isStreaming }

    public func reconnect() {
        if let savedPassword = savedPassword(), !savedPassword.isEmpty {
            passwordPrompt = nil
            connect(with: savedPassword)
        } else {
            passwordPrompt = ""
            passwordInput = ""
        }
    }

    public func submitPassword() {
        let password = passwordInput
        guard !password.isEmpty else { return }
        passwordPrompt = nil
        connect(with: password)
    }

    public func disconnect() {
        session.disconnect(updateState: true)
    }

    public func handleTripleEscape() {
        isKeyboardCaptureEnabled = false
        isMouseCaptureEnabled = false
        toggleFullscreen?()
    }

    public func presentFullscreenBanner() {
        bannerTask?.cancel()
        showFullscreenBanner = true
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.showFullscreenBanner = false
            }
        }
    }

    public func clearFullscreenBanner() {
        bannerTask?.cancel()
        bannerTask = nil
        showFullscreenBanner = false
    }

    public func sendKeyboardReport(_ report: HIDKeyboardReport) {
        guard isKeyboardCaptureEnabled else { return }
        session.sendKeyboardReport(report)
    }

    public func sendMouseReport(_ report: HIDMouseAbsoluteReport) {
        guard isMouseCaptureEnabled else { return }
        session.sendMouseReport(report)
    }

    private func attemptAutoConnect() {
        if let savedPassword = savedPassword(), !savedPassword.isEmpty {
            connect(with: savedPassword)
        } else {
            passwordPrompt = ""
        }
    }

    private func connect(with password: String) {
        session.connect(NanoKVMSessionConfiguration(
            device: device,
            password: password,
            passwordAccount: keychainAccount()
        ))
    }

    private func savedPassword() -> String? {
        do {
            return try passwordStore.password(for: keychainAccount())
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func keychainAccount() -> String {
        KeychainPasswordAccount(
            scheme: device.scheme,
            host: device.host,
            port: device.port,
            username: device.username
        ).rawValue
    }

    private func flushVideo() {
        latestSampleBuffer = nil
        videoSize = nil
        flushToken += 1
    }
}
