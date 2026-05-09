import Foundation
@preconcurrency import CoreMedia

@MainActor
final class ViewerViewModel: ObservableObject {
    @Published var device: Device
    @Published var status: String
    @Published var errorMessage: String?
    @Published var latestSampleBuffer: CMSampleBuffer?
    @Published var videoSize: CGSize?
    @Published var flushToken = 0
    @Published var isKeyboardCaptureEnabled = true
    @Published var isMouseCaptureEnabled = true
    @Published var isScrollInverted = true
    @Published var passwordPrompt: String?
    @Published var passwordInput: String = ""
    @Published var isFullscreen: Bool = false
    @Published var showFullscreenBanner: Bool = false

    var toggleFullscreen: (() -> Void)?

    private let session: NanoKVMSession
    private let passwordStore: PasswordStore
    private var bannerTask: Task<Void, Never>?

    init(device: Device, passwordStore: PasswordStore = KeychainPasswordStore()) {
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

    var isStreaming: Bool { session.isStreaming }

    func reconnect() {
        if let savedPassword = savedPassword(), !savedPassword.isEmpty {
            passwordPrompt = nil
            connect(with: savedPassword)
        } else {
            passwordPrompt = ""
            passwordInput = ""
        }
    }

    func submitPassword() {
        let password = passwordInput
        guard !password.isEmpty else { return }
        passwordPrompt = nil
        connect(with: password)
    }

    func disconnect() {
        session.disconnect(updateState: true)
    }

    func handleTripleEscape() {
        isKeyboardCaptureEnabled = false
        isMouseCaptureEnabled = false
        toggleFullscreen?()
    }

    func presentFullscreenBanner() {
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

    func clearFullscreenBanner() {
        bannerTask?.cancel()
        bannerTask = nil
        showFullscreenBanner = false
    }

    func sendKeyboardReport(_ report: HIDKeyboardReport) {
        guard isKeyboardCaptureEnabled else { return }
        session.sendKeyboardReport(report)
    }

    func sendMouseReport(_ report: HIDMouseAbsoluteReport) {
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
