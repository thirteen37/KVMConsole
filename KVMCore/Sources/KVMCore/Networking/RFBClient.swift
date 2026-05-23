@preconcurrency import CoreMedia
import CoreGraphics
import Foundation
import Network

public actor RFBClient {
    public typealias SampleBufferHandler = @Sendable (CMSampleBuffer) -> Void
    public typealias VideoSizeHandler = @Sendable (CGSize) -> Void
    public typealias AuthenticatedHandler = @Sendable () -> Void

    private let device: Device
    private let profile: RFBSessionProfile
    private let onSampleBuffer: SampleBufferHandler
    private let onVideoSize: VideoSizeHandler
    private let onAuthenticated: AuthenticatedHandler
    private let queue = DispatchQueue(label: "com.kvmconsole.rfb.connection")
    private let framebuffer = RFBFramebuffer()
    private let writer = RFBConnectionWriter()
    private let inputSender: RFBInputSender

    private var connection: NWConnection?
    private var zrleDecoder: RFBZRLEDecoder?
    private var receiveTimeoutSeconds: TimeInterval?
    private var continuousUpdatesActive = false
    private var framebufferPollTask: Task<Void, Never>?

    public init(
        device: Device,
        profile: RFBSessionProfile,
        onSampleBuffer: @escaping SampleBufferHandler,
        onVideoSize: @escaping VideoSizeHandler,
        onAuthenticated: @escaping AuthenticatedHandler = {}
    ) {
        self.device = device
        self.profile = profile
        self.onSampleBuffer = onSampleBuffer
        self.onVideoSize = onVideoSize
        self.onAuthenticated = onAuthenticated
        self.inputSender = RFBInputSender(inputEchoUpdatePolicy: profile.inputEchoUpdatePolicy)
    }

    public func connectAndRun(password: String) async throws {
        KVMLog.rfb.info("Connecting RFB to \(self.device.host, privacy: .public):\(self.device.port, privacy: .public)")
        let connection = makeConnection()
        self.connection = connection
        writer.setConnection(connection)
        try await start(connection)
        KVMLog.rfb.info("RFB TCP connection ready")

        do {
            receiveTimeoutSeconds = 15
            try await handshake(password: password)
            receiveTimeoutSeconds = nil
            try await updateLoop()
        } catch {
            receiveTimeoutSeconds = nil
            close()
            throw error
        }
    }

    public func close() {
        inputSender.cancel()
        framebufferPollTask?.cancel()
        framebufferPollTask = nil
        writer.close()
        connection = nil
    }

    public nonisolated func sendKeyboardReport(
        _ report: HIDKeyboardReport,
        onDrained: (@Sendable () -> Void)? = nil
    ) {
        inputSender.sendKeyboardReport(report, writer: writer, onDrained: onDrained)
    }

    public nonisolated func sendMouseReport(_ report: HIDMouseAbsoluteReport) async {
        inputSender.sendMouseReport(report, writer: writer)
    }

    public nonisolated static func rfbCoordinate(from absoluteValue: UInt16, upperBound: Int) -> UInt16 {
        guard upperBound > 1 else { return 0 }
        let clamped = max(1, min(32_768, Int(absoluteValue)))
        let normalized = Double(clamped - 1) / 32_767.0
        return UInt16((normalized * Double(upperBound - 1)).rounded())
    }

    public nonisolated static func rfbButtonMask(from hidButtons: UInt8) -> UInt8 {
        var mask: UInt8 = 0
        if hidButtons & 0x01 != 0 { mask |= 0x01 }
        if hidButtons & 0x04 != 0 { mask |= 0x02 }
        if hidButtons & 0x02 != 0 { mask |= 0x04 }
        return mask
    }

    static func endpointPort(from devicePort: Int) -> NWEndpoint.Port {
        UInt16(exactly: devicePort).flatMap(NWEndpoint.Port.init(rawValue:)) ?? .rfb
    }

    private func makeConnection() -> NWConnection {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        return NWConnection(
            host: NWEndpoint.Host(device.host),
            port: Self.endpointPort(from: device.port),
            using: parameters
        )
    }

    private func start(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeBox = RFBReadyContinuationBox(continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeBox.resume(.success(()))
                case .failed(let error):
                    resumeBox.resume(.failure(error))
                case .cancelled:
                    resumeBox.resume(.failure(RFBError.connectionClosed))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 15) {
                resumeBox.resume(.failure(RFBError.timeout("opening TCP connection")))
            }
        }
    }

    private func handshake(password: String) async throws {
        let serverGreeting = try await readExact(byteCount: 12)
        let serverVersion = try RFBProtocolVersion(greeting: serverGreeting)
        KVMLog.rfb.info("RFB server version \(serverVersion.major, privacy: .public).\(serverVersion.minor, privacy: .public)")
        guard serverVersion.major == 3, serverVersion.minor >= 8 else {
            throw RFBError.unsupportedProtocolVersion("\(serverVersion.major).\(serverVersion.minor)")
        }
        try await send(RFBProtocolVersion.v3_8.wireData)

        let securityTypeCount = Int(try await readExact(byteCount: 1)[0])
        if securityTypeCount == 0 {
            let reason = try await readReasonString()
            throw RFBError.authenticationFailed(reason)
        }
        let securityBytes = try await readExact(byteCount: securityTypeCount)
        let offered = securityBytes.compactMap(RFBSecurityType.init(rawValue:))
        KVMLog.rfb.info("RFB offered security types: \(securityBytes.map(String.init).joined(separator: ","), privacy: .public)")
        let selected = try RFBAuthentication.selectSecurityType(offered: offered, profile: profile)
        KVMLog.rfb.info("RFB selected security type \(selected.rawValue, privacy: .public)")
        try await send(Data([selected.rawValue]))

        switch selected {
        case .none:
            break
        case .vncAuthentication:
            let challenge = try await readExact(byteCount: 16)
            let response = try RFBAuthentication.vncChallengeResponse(password: password, challenge: challenge)
            try await send(response)
        case .appleDiffieHellman30:
            let keyHeader = try await readExact(byteCount: 4)
            var keyHeaderReader = RFBByteReader(keyHeader)
            let generator = try keyHeaderReader.readUInt16()
            let keySize = Int(try keyHeaderReader.readUInt16())
            KVMLog.rfb.info("RFB Apple DH material received: generator \(generator, privacy: .public), key size \(keySize, privacy: .public)")
            let modulus = try await readExact(byteCount: keySize)
            let serverPublicKey = try await readExact(byteCount: keySize)
            let response = try RFBAuthentication.appleDiffieHellmanResponse(
                username: device.username,
                password: password,
                generator: generator,
                modulus: modulus,
                serverPublicKey: serverPublicKey
            )
            try await send(response)
            KVMLog.rfb.info("RFB Apple DH response sent")
        case .appleSecurity33, .appleSecurity35, .appleSecurity36:
            throw RFBError.authenticationFailed("Apple Screen Sharing security type \(selected.rawValue) is not implemented.")
        case .invalid:
            throw RFBError.authenticationFailed("The server selected an invalid security type.")
        }

        let resultData = try await readExact(byteCount: 4)
        var resultReader = RFBByteReader(resultData)
        let result = try resultReader.readUInt32()
        guard result == 0 else {
            let reason = try? await readReasonString()
            throw RFBError.authenticationFailed(reason ?? "security result \(result)")
        }
        onAuthenticated()

        try await send(Data([1]))
        let serverInit = try await readExact(byteCount: 24)
        var reader = RFBByteReader(serverInit)
        let width = Int(try reader.readUInt16())
        let height = Int(try reader.readUInt16())
        KVMLog.rfb.info("RFB server init framebuffer \(width, privacy: .public)x\(height, privacy: .public)")
        _ = try RFBPixelFormat(reader: &reader)
        let nameLength = Int(try reader.readUInt32())
        if nameLength > 0 {
            _ = try await readExact(byteCount: nameLength)
        }
        try framebuffer.resize(width: width, height: height)
        inputSender.updateFramebufferSize(width: width, height: height)
        onVideoSize(CGSize(width: width, height: height))

        try await send(RFBClientMessage.setPixelFormat(.bgra))
        try await send(RFBClientMessage.setEncodings(preferredEncodings()))
        try await sendFullUpdateRequest(incremental: false)

        if profile.usesContinuousUpdates {
            try await send(RFBClientMessage.enableContinuousUpdates(
                enable: true,
                x: 0,
                y: 0,
                width: UInt16(max(0, min(Int(UInt16.max), width))),
                height: UInt16(max(0, min(Int(UInt16.max), height)))
            ))
            continuousUpdatesActive = true
            KVMLog.rfb.info("RFB ContinuousUpdates requested for full framebuffer")
        }

        if let pollInterval = profile.framebufferPollInterval, pollInterval > 0 {
            startFramebufferPollLoop(interval: pollInterval)
        }
    }

    /// Periodically nudges the server with incremental FBURs so it always
    /// has a request to drain when the framebuffer changes. Apple Screen
    /// Sharing only emits an update when there is a pending FBUR; in
    /// steady-state we already keep one pending from `handleFramebufferUpdate`,
    /// but the inter-update gap stretches as the server's capture cycle
    /// slows down on a quiet screen. Pumping at 30 Hz keeps the cycle hot.
    private func startFramebufferPollLoop(interval: TimeInterval) {
        framebufferPollTask?.cancel()
        let nanos = UInt64(max(0.001, interval) * 1_000_000_000)
        framebufferPollTask = Task(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                guard !Task.isCancelled else { return }
                guard let strongSelf = self else { return }
                await strongSelf.pollFramebufferTick()
            }
        }
        KVMLog.rfb.info("RFB framebuffer poll started at \(1.0 / interval, privacy: .public) Hz")
    }

    private func pollFramebufferTick() {
        sendFullUpdateRequestImmediate(incremental: true)
    }

    private func preferredEncodings() -> [RFBEncoding] {
        var encodings: [RFBEncoding] = [.zrle, .copyRect, .raw, .desktopSize, .lastRect, .fence]
        if profile.usesContinuousUpdates {
            encodings.append(.continuousUpdates)
        }
        return encodings
    }

    private func updateLoop() async throws {
        while !Task.isCancelled {
            let messageType = try await readExact(byteCount: 1)[0]
            switch messageType {
            case 0:
                try await handleFramebufferUpdate()
            case 1:
                try await skipSetColourMapEntries()
            case 2:
                break
            case 3:
                try await skipServerCutText()
            case 150:
                // EndOfContinuousUpdates — a single-byte marker the server
                // sends to acknowledge our `EnableContinuousUpdates(enable=0)`
                // (or, on some servers, the initial enable). Nothing else to
                // read; just clear the local flag so the receive loop falls
                // back to client-pulled updates from here on.
                continuousUpdatesActive = false
                KVMLog.rfb.info("RFB ContinuousUpdates ended by server")
            case 248:
                try await handleServerFence()
            default:
                throw RFBError.malformedMessage("unsupported server message type \(messageType)")
            }
        }
    }

    private func handleFramebufferUpdate() async throws {
        let wireArrivalHostTime = CMClockGetTime(CMClockGetHostTimeClock())
        let header = try await readExact(byteCount: 3)
        var headerReader = RFBByteReader(header)
        try headerReader.skip(1)
        let rectangleCount = Int(try headerReader.readUInt16())

        // Fire-and-forget the next incremental request so the receive loop
        // can immediately start reading rectangle data while the request
        // races toward the server, shaving one network-write round-trip
        // off every framebuffer update cycle. We keep doing this even
        // when `ContinuousUpdates` is in flight: a server that supports
        // CU treats incoming FBURs as harmless triggers, and a server
        // that silently ignored our `EnableContinuousUpdates` (rather
        // than acknowledging or refusing it) still needs FBURs to send
        // anything at all.
        sendFullUpdateRequestImmediate(incremental: true)

        // Buffer every rectangle's metadata + payload first so the actual
        // pixel writes happen inside a single CVPixelBuffer lock below.
        // This also keeps the lock off the network read path.
        var rectangles: [PendingRectangle] = []
        rectangleLoop: for _ in 0..<rectangleCount {
            let rectangleHeader = try await readExact(byteCount: 12)
            var rectangleReader = RFBByteReader(rectangleHeader)
            let rectangle = try RFBRectangle(reader: &rectangleReader)
            switch rectangle.encoding {
            case RFBEncoding.raw.rawValue:
                let bytes = try await readExact(byteCount: Int(rectangle.width) * Int(rectangle.height) * 4)
                rectangles.append(.raw(rectangle, bytes))
            case RFBEncoding.copyRect.rawValue:
                let payload = try await readExact(byteCount: 4)
                var copyReader = RFBByteReader(payload)
                let sourceX = try copyReader.readUInt16()
                let sourceY = try copyReader.readUInt16()
                rectangles.append(.copy(rectangle, sourceX, sourceY))
            case RFBEncoding.zrle.rawValue:
                let lengthData = try await readExact(byteCount: 4)
                var lengthReader = RFBByteReader(lengthData)
                let length = Int(try lengthReader.readUInt32())
                let compressedData = try await readExact(byteCount: length)
                if zrleDecoder == nil {
                    zrleDecoder = try RFBZRLEDecoder()
                }
                rectangles.append(.zrle(rectangle, compressedData))
            case RFBEncoding.desktopSize.rawValue:
                // Any pre-resize rectangles were sized for the old framebuffer
                // dimensions, so applying them to the freshly allocated post-
                // resize buffer would either trip the writer's bounds check or
                // land at wrong coordinates. Discard them — the pre-opt code
                // also lost their visual content here because the old buffer
                // was deallocated by resize().
                rectangles.removeAll(keepingCapacity: true)
                try framebuffer.resize(width: Int(rectangle.width), height: Int(rectangle.height))
                inputSender.updateFramebufferSize(width: Int(rectangle.width), height: Int(rectangle.height))
                onVideoSize(CGSize(width: Int(rectangle.width), height: Int(rectangle.height)))
                try await sendFullUpdateRequest(incremental: false)
                if profile.usesContinuousUpdates {
                    // CU is bound to a rectangle; re-arm it over the new size so
                    // the server keeps pushing covering the whole framebuffer.
                    try await send(RFBClientMessage.enableContinuousUpdates(
                        enable: true,
                        x: 0,
                        y: 0,
                        width: rectangle.width,
                        height: rectangle.height
                    ))
                    continuousUpdatesActive = true
                }
            case RFBEncoding.lastRect.rawValue:
                break rectangleLoop
            default:
                throw RFBError.unsupportedEncoding(rectangle.encoding)
            }
        }

        if rectangles.isEmpty { return }

        try framebuffer.withLockedBuffer { writer in
            for entry in rectangles {
                switch entry {
                case .raw(let rect, let bytes):
                    try writer.applyRaw(rect: rect, bytes: bytes)
                case .copy(let rect, let sourceX, let sourceY):
                    try writer.applyCopyRect(rect: rect, sourceX: sourceX, sourceY: sourceY)
                case .zrle(let rect, let compressedData):
                    try zrleDecoder?.apply(rect: rect, compressedData: compressedData, to: writer)
                }
            }
        }

        let sampleBuffer = try framebuffer.makeSampleBuffer(wireArrivalHostTime: wireArrivalHostTime)
        onSampleBuffer(sampleBuffer)
    }

    private enum PendingRectangle {
        case raw(RFBRectangle, Data)
        case copy(RFBRectangle, UInt16, UInt16)
        case zrle(RFBRectangle, Data)
    }

    private func skipSetColourMapEntries() async throws {
        let header = try await readExact(byteCount: 5)
        var reader = RFBByteReader(header)
        try reader.skip(1)
        _ = try reader.readUInt16()
        let colorCount = Int(try reader.readUInt16())
        if colorCount > 0 {
            _ = try await readExact(byteCount: colorCount * 6)
        }
    }

    private func skipServerCutText() async throws {
        let header = try await readExact(byteCount: 7)
        var reader = RFBByteReader(header)
        try reader.skip(3)
        let length = Int(try reader.readUInt32())
        if length > 0 {
            _ = try await readExact(byteCount: length)
        }
    }

    private func handleServerFence() async throws {
        let data = try await readExact(byteCount: 8)
        var reader = RFBByteReader(data)
        try reader.skip(3)
        let flags = try reader.readUInt32()
        let length = Int(try reader.readUInt8())
        let payload = length > 0 ? try await readExact(byteCount: length) : Data()
        try await send(RFBClientMessage.clientFenceResponse(flags: flags, payload: payload))
    }

    private func sendFullUpdateRequest(incremental: Bool) async throws {
        try await send(makeFullUpdateRequest(incremental: incremental))
    }

    private func sendFullUpdateRequestImmediate(incremental: Bool) {
        writer.sendImmediately(makeFullUpdateRequest(incremental: incremental))
    }

    private func makeFullUpdateRequest(incremental: Bool) -> Data {
        RFBClientMessage.framebufferUpdateRequest(
            incremental: incremental,
            x: 0,
            y: 0,
            width: UInt16(max(0, min(Int(UInt16.max), framebuffer.width))),
            height: UInt16(max(0, min(Int(UInt16.max), framebuffer.height)))
        )
    }

    private func readReasonString() async throws -> String {
        let lengthData = try await readExact(byteCount: 4)
        var reader = RFBByteReader(lengthData)
        let length = Int(try reader.readUInt32())
        guard length > 0 else { return "unknown error" }
        let reasonData = try await readExact(byteCount: length)
        return String(data: reasonData, encoding: .utf8) ?? "unknown error"
    }

    private func readExact(byteCount: Int) async throws -> Data {
        guard byteCount >= 0 else {
            throw RFBError.malformedMessage("negative read length")
        }
        guard byteCount > 0 else { return Data() }
        guard let connection else {
            throw RFBError.connectionClosed
        }

        var result = Data()
        while result.count < byteCount {
            let remaining = byteCount - result.count
            let chunk = try await receive(connection: connection, byteCount: remaining)
            guard !chunk.isEmpty else {
                throw RFBError.connectionClosed
            }
            result.append(chunk)
        }
        return result
    }

    private func receive(connection: NWConnection, byteCount: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let resumeBox = RFBDataContinuationBox(continuation: continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: byteCount) { data, _, isComplete, error in
                if let error {
                    resumeBox.resume(.failure(error))
                    return
                }
                if let data, !data.isEmpty {
                    resumeBox.resume(.success(data))
                    return
                }
                if isComplete {
                    resumeBox.resume(.failure(RFBError.connectionClosed))
                    return
                }
                resumeBox.resume(.success(Data()))
            }
            if let receiveTimeoutSeconds {
                queue.asyncAfter(deadline: .now() + receiveTimeoutSeconds) {
                    resumeBox.resume(.failure(RFBError.timeout("waiting for RFB handshake data")))
                }
            }
        }
    }

    private func send(_ data: Data) async throws {
        try await writer.send(data)
    }

}

private final class RFBConnectionWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?

    func setConnection(_ connection: NWConnection) {
        lock.lock()
        self.connection = connection
        lock.unlock()
    }

    func close() {
        lock.lock()
        let connection = connection
        self.connection = nil
        lock.unlock()
        connection?.cancel()
    }

    func send(_ data: Data) async throws {
        let connection = currentConnection()
        guard let connection else {
            throw RFBError.connectionClosed
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Fire-and-forget send: queues the bytes into NWConnection and returns
    /// immediately. The optional completion fires from NWConnection's
    /// `.contentProcessed` callback so callers that genuinely need to know
    /// when the kernel acknowledged the write (the LatencyBench) can still
    /// observe it without blocking the input path.
    func sendImmediately(_ data: Data, completion: (@Sendable (Error?) -> Void)? = nil) {
        let connection = currentConnection()
        guard let connection else {
            completion?(RFBError.connectionClosed)
            return
        }
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                KVMLog.rfb.error("RFB send failed: \(error.localizedDescription, privacy: .public)")
            }
            completion?(error)
        })
    }

    private func currentConnection() -> NWConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connection
    }
}

private final class RFBInputSender: @unchecked Sendable {
    private let lock = NSLock()
    private let inputEchoUpdateRequester: RFBInputEchoUpdateRequester
    private var previousKeyboardReport = HIDKeyboardReport()
    private var framebufferWidth = 0
    private var framebufferHeight = 0

    init(inputEchoUpdatePolicy: RFBInputEchoUpdatePolicy) {
        self.inputEchoUpdateRequester = RFBInputEchoUpdateRequester(policy: inputEchoUpdatePolicy)
    }

    func cancel() {
        lock.lock()
        previousKeyboardReport = HIDKeyboardReport()
        lock.unlock()
    }

    func updateFramebufferSize(width: Int, height: Int) {
        lock.lock()
        framebufferWidth = width
        framebufferHeight = height
        lock.unlock()
        inputEchoUpdateRequester.updateFramebufferSize(width: width, height: height)
    }

    /// Synchronously builds the wire bytes for the report's transitions
    /// (plus an optional echo update request) and hands them to the writer
    /// as a single fire-and-forget send. No drain task, no per-transition
    /// awaits — the caller's main-thread call now reaches NWConnection with
    /// only a lock acquire and a single `connection.send` between the input
    /// event and the network framework.
    func sendKeyboardReport(
        _ report: HIDKeyboardReport,
        writer: RFBConnectionWriter,
        onDrained: (@Sendable () -> Void)? = nil
    ) {
        lock.lock()
        let transitions: [HIDUsageToX11Keysym.KeyTransition]
        if report == previousKeyboardReport {
            transitions = HIDUsageToX11Keysym.repeatTransitions(for: report)
        } else {
            transitions = HIDUsageToX11Keysym.transitions(from: previousKeyboardReport, to: report)
        }
        previousKeyboardReport = report
        lock.unlock()

        guard !transitions.isEmpty else {
            onDrained?()
            return
        }

        var data = Data()
        data.reserveCapacity(transitions.count * 8 + 10)
        for transition in transitions {
            data.append(RFBClientMessage.keyEvent(down: transition.isDown, keysym: transition.keysym))
        }
        if let echoRequest = inputEchoUpdateRequester.updateRequestAfterTransitions(transitions) {
            data.append(echoRequest.data)
        }

        writer.sendImmediately(data) { _ in
            onDrained?()
        }
    }

    func sendMouseReport(_ report: HIDMouseAbsoluteReport, writer: RFBConnectionWriter) {
        let size = framebufferSize()

        guard size.width > 0, size.height > 0 else { return }
        let x = RFBClient.rfbCoordinate(from: report.x, upperBound: size.width)
        let y = RFBClient.rfbCoordinate(from: report.y, upperBound: size.height)
        let baseMask = RFBClient.rfbButtonMask(from: report.buttons)

        var data = Data()
        if report.wheel == 0 {
            data.append(RFBClientMessage.pointerEvent(buttonMask: baseMask, x: x, y: y))
        } else {
            let wheelMask: UInt8 = report.wheel > 0 ? 0x08 : 0x10
            let notches = abs(Int(report.wheel))
            data.reserveCapacity(notches * 12)
            for _ in 0..<notches {
                data.append(RFBClientMessage.pointerEvent(buttonMask: baseMask | wheelMask, x: x, y: y))
                data.append(RFBClientMessage.pointerEvent(buttonMask: baseMask, x: x, y: y))
            }
        }

        writer.sendImmediately(data)
    }

    private func framebufferSize() -> (width: Int, height: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (framebufferWidth, framebufferHeight)
    }
}

final class RFBInputEchoUpdateRequester: @unchecked Sendable {
    struct Request: Equatable {
        let data: Data
    }

    private let lock = NSLock()
    private let policy: RFBInputEchoUpdatePolicy
    private var framebufferWidth = 0
    private var framebufferHeight = 0
    private var lastRequestUptimeNanoseconds: UInt64?

    init(policy: RFBInputEchoUpdatePolicy) {
        self.policy = policy
    }

    func updateFramebufferSize(width: Int, height: Int) {
        lock.lock()
        framebufferWidth = width
        framebufferHeight = height
        lock.unlock()
    }

    func updateRequestAfterKeyboardEvent(
        isKeyDown: Bool,
        nowUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Request? {
        guard case .keyboard(_, let trigger) = policy else { return nil }
        guard trigger.matches(isKeyDown: isKeyDown) else { return nil }
        return makeRequestIfWithinThrottle(nowUptimeNanoseconds: nowUptimeNanoseconds)
    }

    /// Single-call variant for the batched send path: if any of the report's
    /// transitions matches the trigger and the throttle allows, returns one
    /// request to be appended to the keystroke's outgoing TCP segment. This
    /// keeps the keyEvent bytes and the framebuffer-update-request bytes in
    /// the same packet so Apple Screen Sharing sees both in a single poll.
    func updateRequestAfterTransitions(
        _ transitions: [HIDUsageToX11Keysym.KeyTransition],
        nowUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Request? {
        guard case .keyboard(_, let trigger) = policy else { return nil }
        guard transitions.contains(where: { trigger.matches(isKeyDown: $0.isDown) }) else { return nil }
        return makeRequestIfWithinThrottle(nowUptimeNanoseconds: nowUptimeNanoseconds)
    }

    private func makeRequestIfWithinThrottle(nowUptimeNanoseconds: UInt64) -> Request? {
        lock.lock()
        defer { lock.unlock() }

        guard case .keyboard(let minimumInterval, _) = policy else { return nil }
        guard framebufferWidth > 0, framebufferHeight > 0 else { return nil }

        let throttleNanoseconds = Self.nanoseconds(for: minimumInterval)
        if let lastRequestUptimeNanoseconds,
           nowUptimeNanoseconds >= lastRequestUptimeNanoseconds,
           nowUptimeNanoseconds - lastRequestUptimeNanoseconds < throttleNanoseconds {
            return nil
        }

        lastRequestUptimeNanoseconds = nowUptimeNanoseconds
        return Request(
            data: RFBClientMessage.framebufferUpdateRequest(
                incremental: true,
                x: 0,
                y: 0,
                width: UInt16(max(0, min(Int(UInt16.max), framebufferWidth))),
                height: UInt16(max(0, min(Int(UInt16.max), framebufferHeight)))
            )
        )
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        let nanoseconds = max(0, interval) * 1_000_000_000
        guard nanoseconds < Double(UInt64.max) else { return UInt64.max }
        return UInt64(nanoseconds.rounded(.up))
    }
}

private extension RFBInputEchoUpdateTrigger {
    func matches(isKeyDown: Bool) -> Bool {
        switch self {
        case .keyDown:
            return isKeyDown
        case .keyUp:
            return !isKeyDown
        case .any:
            return true
        }
    }
}

private extension NWEndpoint.Port {
    static let rfb = NWEndpoint.Port(rawValue: 5900)!
}

private final class RFBReadyContinuationBox: @unchecked Sendable {
    private let continuation: CheckedContinuation<Void, Error>
    private let lock = NSLock()
    private var didResume = false

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()

        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private final class RFBDataContinuationBox: @unchecked Sendable {
    private let continuation: CheckedContinuation<Data, Error>
    private let lock = NSLock()
    private var didResume = false

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Data, Error>) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()

        switch result {
        case .success(let data):
            continuation.resume(returning: data)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
