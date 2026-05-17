import Combine
import Foundation

@MainActor
public final class ViewerViewModel: ObservableObject {
    @Published public var device: Device
    @Published public var status: String
    @Published public var errorMessage: String?
    @Published public var videoSize: CGSize?
    @Published public var isKeyboardCaptureEnabled = true
    @Published public var isMouseCaptureEnabled = true
    @Published public var isScrollInverted = true
    @Published public var passwordPrompt: String?
    @Published public var passwordInput: String = ""
    @Published public var isFullscreen: Bool = false
    @Published public var showFullscreenBanner: Bool = false

    public var toggleFullscreen: (() -> Void)?
    public let renderCoordinator: SampleBufferRenderCoordinator
    public let zoom = ViewerZoomState()

    private let session: NanoKVMSession
    private let passwordStore: PasswordStore
    private let onConnected: ((Device.ID) -> Void)?
    private var bannerTask: Task<Void, Never>?
    private var zoomObservers: Set<AnyCancellable> = []

    public init(
        device: Device,
        passwordStore: PasswordStore = KeychainPasswordStore(),
        onConnected: ((Device.ID) -> Void)? = nil
    ) {
        let renderCoordinator = SampleBufferRenderCoordinator()
        self.device = device
        self.passwordStore = passwordStore
        self.onConnected = onConnected
        self.renderCoordinator = renderCoordinator
        self.session = NanoKVMSession(passwordStore: passwordStore, renderCoordinator: renderCoordinator)
        self.status = NanoKVMSessionState.disconnected.displayText

        session.onStateChange = { [weak self] state in
            guard let self else { return }
            self.status = state.displayText
            self.errorMessage = state.errorMessage
            if state == .streaming {
                self.onConnected?(self.device.id)
            }
        }
        session.onVideoSize = { [weak self] videoSize in
            guard let self else { return }
            if self.videoSize != videoSize {
                self.videoSize = videoSize
                self.zoom.videoSize = videoSize
            }
        }
        session.onFlush = { [weak self] in
            self?.flushVideo()
        }

        // Forward only scale/center changes — the body uses those to drive VideoRenderView. Other
        // zoom @Published fields (notably the per-mouse-event cursorNormalized) would re-render the
        // viewer and re-run updateUIView/updateNSView on every cursor move; MinimapView observes
        // the zoom directly via @ObservedObject and handles those updates on its own.
        zoom.$scale.dropFirst().map { _ in () }
            .merge(with: zoom.$center.dropFirst().map { _ in () })
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &zoomObservers)

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
        renderCoordinator.flush()
        videoSize = nil
        zoom.videoSize = nil
        zoom.cursorNormalized = nil
        zoom.reset()
    }
}
