@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@preconcurrency import WebRTC
import Foundation

public enum WebRTCPipelineError: Error, LocalizedError, Equatable {
    case invalidURL
    case invalidMessage
    case missingSessionID
    case missingHandleID
    case missingOffer
    case missingPeerConnection
    case peerConnectionCreationFailed
    case signaling(String)
    case plugin(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid GLKVM Janus WebSocket URL."
        case .invalidMessage:
            return "Received an invalid Janus message."
        case .missingSessionID:
            return "Janus did not return a session ID."
        case .missingHandleID:
            return "Janus did not return a plugin handle ID."
        case .missingOffer:
            return "Janus did not provide a WebRTC offer."
        case .missingPeerConnection:
            return "WebRTC peer connection is not available."
        case .peerConnectionCreationFailed:
            return "Could not create a WebRTC peer connection."
        case .signaling(let message):
            return "WebRTC signaling failed: \(message)"
        case .plugin(let message):
            return "GLKVM video failed: \(message)"
        }
    }
}

public final class WebRTCPipeline: NSObject, @unchecked Sendable {
    private let device: Device
    private let authToken: String
    private let renderCoordinator: SampleBufferRenderCoordinator
    private let onVideoSize: @Sendable (CGSize?) -> Void
    private let onError: @Sendable (Error) -> Void
    private let session: URLSession
    private let renderer: RTCVideoFrameCMSampleBufferRenderer
    private let lock = NSLock()

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var peerConnection: RTCPeerConnection?
    private var peerConnectionFactory: RTCPeerConnectionFactory?
    private var videoTrack: RTCVideoTrack?
    private var sessionID: Int64?
    private var handleID: Int64?

    public init(
        device: Device,
        authToken: String,
        renderCoordinator: SampleBufferRenderCoordinator,
        onVideoSize: @escaping @Sendable (CGSize?) -> Void = { _ in },
        onError: @escaping @Sendable (Error) -> Void = { _ in }
    ) {
        self.device = device
        self.authToken = authToken
        self.renderCoordinator = renderCoordinator
        self.onVideoSize = onVideoSize
        self.onError = onError
        renderer = RTCVideoFrameCMSampleBufferRenderer(
            renderCoordinator: renderCoordinator,
            onVideoSize: onVideoSize
        )

        session = Self.makeSession(device: device, authToken: authToken)

        super.init()
    }

    deinit {
        stop()
    }

    public func start() async throws {
        guard webSocketTask == nil else { return }
        guard let url = janusURL else { throw WebRTCPipelineError.invalidURL }

        KVMLog.webrtc.info("Opening GLKVM Janus WebSocket: \(url.absoluteString, privacy: .public)")
        let task = session.webSocketTask(with: url, protocols: ["janus-protocol"])
        task.priority = URLSessionTask.highPriority
        storeWebSocketTask(task)
        task.resume()

        let sessionResponse = try await sendAndWait(
            JanusMessage.create(transaction: makeTransaction()),
            task: task,
            matching: { $0.janus == "success" && $0.transaction != nil && $0.data?.id != nil }
        )
        guard let sessionID = sessionResponse.data?.id else { throw WebRTCPipelineError.missingSessionID }
        storeSessionID(sessionID)
        KVMLog.webrtc.info("GLKVM Janus session created: \(sessionID, privacy: .public)")

        let attachResponse = try await sendAndWait(
            JanusMessage.attach(sessionID: sessionID, transaction: makeTransaction()),
            task: task,
            matching: { $0.janus == "success" && $0.transaction != nil && $0.data?.id != nil }
        )
        guard let handleID = attachResponse.data?.id else { throw WebRTCPipelineError.missingHandleID }
        storeHandleID(handleID)
        KVMLog.webrtc.info("GLKVM uStreamer plugin attached: \(handleID, privacy: .public)")

        let featuresResponse = try await sendAndWait(
            JanusMessage.features(sessionID: sessionID, handleID: handleID, transaction: makeTransaction()),
            task: task,
            matching: { $0.pluginData?.data?.result?.status == "features" }
        )
        let iceServerURL = featuresResponse.pluginData?.data?.result?.features?.ice?.url
        KVMLog.webrtc.info("GLKVM uStreamer features received; ICE server present: \((iceServerURL?.isEmpty == false), privacy: .public)")

        let peerConnection = try makePeerConnection(iceServerURL: iceServerURL)
        storePeerConnection(peerConnection)
        KVMLog.webrtc.info("GLKVM WebRTC peer connection created")

        let offerResponse = try await sendAndWait(
            JanusMessage.watch(sessionID: sessionID, handleID: handleID, transaction: makeTransaction()),
            task: task,
            matching: { $0.jsep?.type == "offer" }
        )
        guard let offer = offerResponse.jsep else { throw WebRTCPipelineError.missingOffer }
        KVMLog.webrtc.info("GLKVM WebRTC offer received: \(Self.describe(sdp: offer.sdp), privacy: .public)")

        let remoteDescription = RTCSessionDescription(type: RTCSdpType.offer, sdp: offer.sdp)
        try await setRemoteDescription(remoteDescription, on: peerConnection)
        let answerJSEP = try await createAndSetLocalAnswer(on: peerConnection)
        KVMLog.webrtc.info("GLKVM WebRTC answer created: \(Self.describe(sdp: answerJSEP.sdp), privacy: .public)")
        _ = try await sendAndWait(
            JanusMessage.start(
                sessionID: sessionID,
                handleID: handleID,
                transaction: makeTransaction(),
                jsep: answerJSEP
            ),
            task: task,
            matching: { $0.pluginData?.data?.result?.status == "started" }
        )
        KVMLog.webrtc.info("GLKVM uStreamer reported started")

        startKeepAliveLoop(sessionID: sessionID, task: task)
        startReceiveLoop(task: task)
    }

    public func stop() {
        let snapshot = takeStopSnapshot()

        snapshot.videoTrack?.remove(renderer)
        snapshot.peerConnection?.close()

        if let task = snapshot.webSocketTask, let sessionID = snapshot.sessionID {
            Task { [sessionID] in
                try? await self.send(
                    JanusMessage.destroy(sessionID: sessionID, transaction: self.makeTransaction()),
                    task: task
                )
                task.cancel(with: .goingAway, reason: nil)
            }
        } else {
            snapshot.webSocketTask?.cancel(with: .goingAway, reason: nil)
        }

        renderCoordinator.flush()
        onVideoSize(nil)
    }

    private func makePeerConnection(iceServerURL: String?) throws -> RTCPeerConnection {
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        let factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        storePeerConnectionFactory(factory)

        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.tcpCandidatePolicy = .disabled
        configuration.candidateNetworkPolicy = .all
        configuration.continualGatheringPolicy = .gatherOnce
        configuration.disableIPV6OnWiFi = true
        configuration.disableLinkLocalNetworks = true
        configuration.enableIceGatheringOnAnyAddressPorts = true
        if let iceServerURL, !iceServerURL.isEmpty {
            configuration.iceServers = [RTCIceServer(urlStrings: [iceServerURL])]
            KVMLog.webrtc.info("Using GLKVM ICE server: \(iceServerURL, privacy: .public)")
        } else {
            configuration.iceServers = []
            KVMLog.webrtc.info("No GLKVM ICE server advertised")
        }

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = factory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: self
        ) else {
            throw WebRTCPipelineError.peerConnectionCreationFailed
        }

        return peerConnection
    }

    private static func makeSession(device: Device, authToken: String) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["Cookie": "auth_token=\(authToken)"]

        if device.allowsInsecureTLS {
            let delegate = InsecureTLSDelegate(allowsInsecureTLS: true)
            return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        }

        return URLSession(configuration: configuration)
    }

    private func createAndSetLocalAnswer(on peerConnection: RTCPeerConnection) async throws -> JanusJSEP {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveVideo": "true",
                "OfferToReceiveAudio": "false",
            ],
            optionalConstraints: nil
        )

        return try await withCheckedThrowingContinuation { continuation in
            peerConnection.answer(for: constraints) { sdp, error in
                if let error {
                    continuation.resume(throwing: WebRTCPipelineError.signaling(error.localizedDescription))
                    return
                }

                guard let sdp else {
                    continuation.resume(throwing: WebRTCPipelineError.signaling("No SDP answer was produced."))
                    return
                }

                peerConnection.setLocalDescription(sdp) { error in
                    if let error {
                        continuation.resume(throwing: WebRTCPipelineError.signaling(error.localizedDescription))
                    } else {
                        continuation.resume(
                            returning: JanusJSEP(
                                type: RTCSessionDescription.string(for: sdp.type).lowercased(),
                                sdp: sdp.sdp
                            )
                        )
                    }
                }
            }
        }
    }

    private func setRemoteDescription(
        _ description: RTCSessionDescription,
        on peerConnection: RTCPeerConnection
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: WebRTCPipelineError.signaling(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func sendAndWait(
        _ payload: [String: Any],
        task: URLSessionWebSocketTask,
        matching predicate: (JanusResponse) -> Bool
    ) async throws -> JanusResponse {
        let transaction = payload["transaction"] as? String
        try await send(payload, task: task)

        while !Task.isCancelled {
            let response = try await receiveResponse(from: task)
            try handlePluginError(response)
            handle(response)

            if let transaction, response.janus == "ack", response.transaction == transaction {
                continue
            }
            if predicate(response) {
                return response
            }
        }

        throw CancellationError()
    }

    private func send(_ payload: [String: Any], task: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let text = String(data: data, encoding: .utf8) else {
            throw WebRTCPipelineError.invalidMessage
        }
        try await task.send(.string(text))
    }

    private func receiveResponse(from task: URLSessionWebSocketTask) async throws -> JanusResponse {
        let message = try await task.receive()
        let data: Data
        switch message {
        case .data(let payload):
            data = payload
        case .string(let text):
            data = Data(text.utf8)
        @unknown default:
            throw WebRTCPipelineError.invalidMessage
        }
        let response = try JSONDecoder().decode(JanusResponse.self, from: data)
        KVMLog.webrtc.info("Received Janus message: \(response.logDescription, privacy: .public)")
        return response
    }

    private func handlePluginError(_ response: JanusResponse) throws {
        if let error = response.pluginData?.data?.error {
            throw WebRTCPipelineError.plugin(error)
        }
        if let code = response.pluginData?.data?.errorCode {
            throw WebRTCPipelineError.plugin("uStreamer error \(code).")
        }
    }

    private func startReceiveLoop(task: URLSessionWebSocketTask) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    let response = try await self.receiveResponse(from: task)
                    try self.handlePluginError(response)
                    self.handle(response)
                } catch {
                    if !Task.isCancelled {
                        self?.onError(error)
                    }
                    return
                }
            }
        }
    }

    private func handle(_ response: JanusResponse?) {
        guard let response else { return }

        if response.janus == "trickle", let candidate = response.candidate {
            KVMLog.webrtc.info("Received GLKVM remote ICE candidate")
            addRemoteCandidate(candidate)
        } else if response.janus == "webrtcup" {
            KVMLog.webrtc.info("GLKVM WebRTC media path is up")
            sendKeyRequired()
            startStatsLoop()
        } else if response.pluginData?.data?.result?.status == "stopped" {
            onError(WebRTCPipelineError.plugin("uStreamer stopped the WebRTC stream."))
        }
    }

    private func addRemoteCandidate(_ candidate: JanusCandidate) {
        guard
            candidate.completed != true,
            let sdp = candidate.candidate,
            let sdpMLineIndex = candidate.sdpMLineIndex,
            let peerConnection = currentPeerConnection()
        else { return }

        let rtcCandidate = RTCIceCandidate(
            sdp: sdp,
            sdpMLineIndex: sdpMLineIndex,
            sdpMid: candidate.sdpMid
        )
        peerConnection.add(rtcCandidate) { _ in }
    }

    private func startKeepAliveLoop(sessionID: Int64, task: URLSessionWebSocketTask) {
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                try? await self.send(
                    JanusMessage.keepAlive(sessionID: sessionID, transaction: self.makeTransaction()),
                    task: task
                )
            }
        }
    }

    private func sendLocalCandidate(
        sdp: String,
        sdpMid: String?,
        sdpMLineIndex: Int32
    ) {
        guard let snapshot = currentJanusSnapshot() else { return }
        KVMLog.webrtc.info("Sending GLKVM local ICE candidate: \(Self.describe(candidateSDP: sdp), privacy: .public)")

        Task { [weak self] in
            guard let self else { return }
            try? await self.send(
                JanusMessage.trickle(
                    sessionID: snapshot.sessionID,
                    handleID: snapshot.handleID,
                    transaction: self.makeTransaction(),
                    candidate: JanusCandidate(candidate: sdp, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex)
                ),
                task: snapshot.task
            )
        }
    }

    private func sendLocalCandidatesCompleted() {
        guard let snapshot = currentJanusSnapshot() else { return }
        KVMLog.webrtc.info("Sending GLKVM local ICE candidates completed")

        Task { [weak self] in
            guard let self else { return }
            try? await self.send(
                JanusMessage.trickle(
                    sessionID: snapshot.sessionID,
                    handleID: snapshot.handleID,
                    transaction: self.makeTransaction(),
                    candidate: JanusCandidate(completed: true)
                ),
                task: snapshot.task
            )
        }
    }

    private func sendKeyRequired() {
        guard let snapshot = currentJanusSnapshot() else { return }
        KVMLog.webrtc.info("Sending GLKVM keyframe request")

        Task { [weak self] in
            guard let self else { return }
            try? await self.send(
                JanusMessage.keyRequired(
                    sessionID: snapshot.sessionID,
                    handleID: snapshot.handleID,
                    transaction: self.makeTransaction()
                ),
                task: snapshot.task
            )

            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            try? await self.send(
                JanusMessage.keyRequired(
                    sessionID: snapshot.sessionID,
                    handleID: snapshot.handleID,
                    transaction: self.makeTransaction()
                ),
                task: snapshot.task
            )
        }
    }

    private func startStatsLoop() {
        lock.lock()
        guard statsTask == nil else {
            lock.unlock()
            return
        }
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.logStatsSnapshot()
            }
        }
        lock.unlock()
    }

    private func logStatsSnapshot() {
        guard let peerConnection = currentPeerConnection() else { return }

        peerConnection.statistics { [weak self] report in
            self?.log(report: report)
        }
    }

    private func log(report: RTCStatisticsReport) {
        for stat in report.statistics.values where Self.isInboundVideo(stat) {
            let values = stat.values
            let bytes = Self.describe(values["bytesReceived"])
            let packets = Self.describe(values["packetsReceived"])
            let framesReceived = Self.describe(values["framesReceived"])
            let framesDecoded = Self.describe(values["framesDecoded"])
            let keyFramesDecoded = Self.describe(values["keyFramesDecoded"])
            let decoder = Self.describe(values["decoderImplementation"])
            KVMLog.webrtc.info(
                "GLKVM WebRTC inbound video stats: bytes=\(bytes, privacy: .public) packets=\(packets, privacy: .public) framesReceived=\(framesReceived, privacy: .public) framesDecoded=\(framesDecoded, privacy: .public) keyFramesDecoded=\(keyFramesDecoded, privacy: .public) decoder=\(decoder, privacy: .public)"
            )
        }

        if let pair = Self.selectedCandidatePair(in: report) {
            let values = pair.values
            let state = Self.describe(values["state"])
            let bytesReceived = Self.describe(values["bytesReceived"])
            let bytesSent = Self.describe(values["bytesSent"])
            let roundTrip = Self.describe(values["currentRoundTripTime"])
            let localID = Self.describe(values["localCandidateId"])
            let remoteID = Self.describe(values["remoteCandidateId"])
            KVMLog.webrtc.info(
                "GLKVM WebRTC candidate pair stats: state=\(state, privacy: .public) bytesReceived=\(bytesReceived, privacy: .public) bytesSent=\(bytesSent, privacy: .public) rtt=\(roundTrip, privacy: .public) local=\(localID, privacy: .public) remote=\(remoteID, privacy: .public)"
            )
            logCandidateDetails(report: report, localID: localID, remoteID: remoteID)
        }
    }

    private func logCandidateDetails(report: RTCStatisticsReport, localID: String, remoteID: String) {
        if let local = report.statistics[localID] {
            KVMLog.webrtc.info("GLKVM WebRTC local candidate: \(Self.describe(candidateStat: local), privacy: .public)")
        }
        if let remote = report.statistics[remoteID] {
            KVMLog.webrtc.info("GLKVM WebRTC remote candidate: \(Self.describe(candidateStat: remote), privacy: .public)")
        }
    }

    private func install(videoTrack: RTCVideoTrack) {
        lock.lock()
        let oldTrack = self.videoTrack
        self.videoTrack = videoTrack
        lock.unlock()

        if oldTrack !== videoTrack {
            oldTrack?.remove(renderer)
            videoTrack.add(renderer)
        }
    }

    private var janusURL: URL? {
        var components = URLComponents()
        components.scheme = device.webSocketScheme
        components.host = device.host
        let isDefaultPort = (device.scheme == .http && device.port == 80) || (device.scheme == .https && device.port == 443)
        if !isDefaultPort {
            components.port = device.port
        }
        components.path = "/janus/ws"
        return components.url
    }

    private func makeTransaction() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private func storeWebSocketTask(_ task: URLSessionWebSocketTask) {
        lock.lock()
        webSocketTask = task
        lock.unlock()
    }

    private func storeSessionID(_ id: Int64) {
        lock.lock()
        sessionID = id
        lock.unlock()
    }

    private func storeHandleID(_ id: Int64) {
        lock.lock()
        handleID = id
        lock.unlock()
    }

    private func storePeerConnection(_ peerConnection: RTCPeerConnection) {
        lock.lock()
        self.peerConnection = peerConnection
        lock.unlock()
    }

    private func storePeerConnectionFactory(_ factory: RTCPeerConnectionFactory) {
        lock.lock()
        peerConnectionFactory = factory
        lock.unlock()
    }

    private func currentPeerConnection() -> RTCPeerConnection? {
        lock.lock()
        let peerConnection = peerConnection
        lock.unlock()
        return peerConnection
    }

    private func currentJanusSnapshot() -> (task: URLSessionWebSocketTask, sessionID: Int64, handleID: Int64)? {
        lock.lock()
        defer { lock.unlock() }

        guard let webSocketTask, let sessionID, let handleID else { return nil }
        return (webSocketTask, sessionID, handleID)
    }

    private func takeStopSnapshot() -> (
        webSocketTask: URLSessionWebSocketTask?,
        peerConnection: RTCPeerConnection?,
        videoTrack: RTCVideoTrack?,
        sessionID: Int64?
    ) {
        lock.lock()
        receiveTask?.cancel()
        keepAliveTask?.cancel()
        statsTask?.cancel()
        let snapshot = (webSocketTask, peerConnection, videoTrack, sessionID)
        receiveTask = nil
        keepAliveTask = nil
        statsTask = nil
        webSocketTask = nil
        peerConnection = nil
        peerConnectionFactory = nil
        videoTrack = nil
        sessionID = nil
        handleID = nil
        lock.unlock()
        return snapshot
    }
}

extension WebRTCPipeline: RTCPeerConnectionDelegate {
    public func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange stateChanged: RTCSignalingState
    ) {
        KVMLog.webrtc.info("GLKVM signaling state changed: \(stateChanged.rawValue, privacy: .public)")
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let videoTrack = stream.videoTracks.first {
            install(videoTrack: videoTrack)
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    public func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceConnectionState
    ) {
        KVMLog.webrtc.info("GLKVM ICE connection state changed: \(Self.describe(newState), privacy: .public)")
        if newState == .failed || newState == .disconnected {
            onError(WebRTCPipelineError.signaling("ICE connection \(Self.describe(newState))."))
        }
    }

    public func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceGatheringState
    ) {
        KVMLog.webrtc.info("GLKVM ICE gathering state changed: \(newState.rawValue, privacy: .public)")
        if newState == .complete {
            sendLocalCandidatesCompleted()
        }
    }

    public func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didGenerate candidate: RTCIceCandidate
    ) {
        KVMLog.webrtc.info("Generated GLKVM local ICE candidate")
        sendLocalCandidate(
            sdp: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex
        )
    }

    public func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove candidates: [RTCIceCandidate]
    ) {}

    public func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didOpen dataChannel: RTCDataChannel
    ) {}

    public func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCPeerConnectionState
    ) {
        KVMLog.webrtc.info("GLKVM peer connection state changed: \(Self.describe(newState), privacy: .public)")
    }

    public func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        if let videoTrack = rtpReceiver.track as? RTCVideoTrack {
            KVMLog.webrtc.info("GLKVM remote video track received")
            install(videoTrack: videoTrack)
        }
    }

    private static func describe(_ state: RTCIceConnectionState) -> String {
        switch state {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        case .count: return "count"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    private static func describe(_ state: RTCPeerConnectionState) -> String {
        switch state {
        case .new: return "new"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .failed: return "failed"
        case .closed: return "closed"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    private static func describe(candidateSDP: String) -> String {
        let fields = candidateSDP.split(separator: " ").map(String.init)
        var type = "unknown"
        var transport = fields.count > 2 ? fields[2] : "?"
        var address = fields.count > 4 ? fields[4] : "?"
        var port = fields.count > 5 ? fields[5] : "?"

        for index in fields.indices where fields[index] == "typ" {
            let next = fields.index(after: index)
            if fields.indices.contains(next) {
                type = fields[next]
            }
            break
        }

        if transport.isEmpty { transport = "?" }
        if address.isEmpty { address = "?" }
        if port.isEmpty { port = "?" }
        return "type=\(type) transport=\(transport) address=\(address):\(port)"
    }

    private static func describe(sdp: String) -> String {
        var videoSections: [String] = []
        var currentMediaLine: String?
        var currentDirections: [String] = []
        var currentCodecs: [String] = []
        var inVideoSection = false

        func appendCurrentSection() {
            guard let currentMediaLine else { return }
            videoSections.append(
                "media=\"\(currentMediaLine)\" directions=\(currentDirections.joined(separator: ",")) codecs=\(currentCodecs.joined(separator: ","))"
            )
        }

        for rawLine in sdp.split(whereSeparator: \.isNewline).map(String.init) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("m=") {
                appendCurrentSection()
                inVideoSection = line.hasPrefix("m=video")
                if inVideoSection {
                    currentMediaLine = line
                    currentDirections = []
                    currentCodecs = []
                } else {
                    currentMediaLine = nil
                    currentDirections = []
                    currentCodecs = []
                }
                continue
            }

            guard inVideoSection else { continue }
            if ["a=sendrecv", "a=sendonly", "a=recvonly", "a=inactive"].contains(line) {
                currentDirections.append(String(line.dropFirst(2)))
            } else if line.hasPrefix("a=rtpmap:"), currentCodecs.count < 8 {
                currentCodecs.append(String(line.dropFirst("a=rtpmap:".count)))
            }
        }
        appendCurrentSection()

        return videoSections.isEmpty ? "videoSections=-" : videoSections.joined(separator: " | ")
    }

    private static func isInboundVideo(_ stat: RTCStatistics) -> Bool {
        guard stat.type == "inbound-rtp" else { return false }
        let values = stat.values
        if describe(values["kind"]) == "video" || describe(values["mediaType"]) == "video" {
            return true
        }
        return stat.id.localizedCaseInsensitiveContains("video")
    }

    private static func selectedCandidatePair(in report: RTCStatisticsReport) -> RTCStatistics? {
        report.statistics.values.first { stat in
            guard stat.type == "candidate-pair" else { return false }
            let values = stat.values
            if describe(values["state"]) == "succeeded" {
                return true
            }
            return describe(values["selected"]) == "true" || describe(values["nominated"]) == "true"
        }
    }

    private static func describe(_ value: NSObject?) -> String {
        guard let value else { return "-" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        if let string = value as? NSString {
            return string as String
        }
        return value.description
    }

    private static func describe(candidateStat stat: RTCStatistics) -> String {
        let values = stat.values
        let candidateType = describe(values["candidateType"])
        let protocolValue = describe(values["protocol"])
        let address = describe(values["address"]) != "-" ? describe(values["address"]) : describe(values["ip"])
        let port = describe(values["port"])
        let relayProtocol = describe(values["relayProtocol"])
        return "id=\(stat.id) type=\(stat.type) candidateType=\(candidateType) protocol=\(protocolValue) address=\(address):\(port) relayProtocol=\(relayProtocol)"
    }
}

private final class RTCVideoFrameCMSampleBufferRenderer: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let renderCoordinator: SampleBufferRenderCoordinator
    private let onVideoSize: @Sendable (CGSize?) -> Void
    private let lock = NSLock()
    private var frameCount = 0
    private var conversionDropCount = 0
    private var sampleBufferDropCount = 0

    init(
        renderCoordinator: SampleBufferRenderCoordinator,
        onVideoSize: @escaping @Sendable (CGSize?) -> Void
    ) {
        self.renderCoordinator = renderCoordinator
        self.onVideoSize = onVideoSize
        super.init()
    }

    func setSize(_ size: CGSize) {
        KVMLog.webrtc.info("GLKVM renderer video size: \(Int(size.width), privacy: .public)x\(Int(size.height), privacy: .public)")
        onVideoSize(size)
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }

        guard let pixelBuffer = makePixelBuffer(from: frame.buffer) else {
            logDrop(kind: "pixel-buffer-conversion")
            return
        }
        guard let sampleBuffer = makeSampleBuffer(from: pixelBuffer, timestampNs: frame.timeStampNs) else {
            logDrop(kind: "sample-buffer")
            return
        }

        logFrame(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))

        markDisplayImmediately(sampleBuffer)
        renderCoordinator.enqueue(sampleBuffer)
    }

    private func logFrame(width: Int, height: Int) {
        lock.lock()
        frameCount += 1
        let count = frameCount
        lock.unlock()

        if count == 1 || count % 120 == 0 {
            KVMLog.webrtc.info("GLKVM rendered WebRTC frame \(count, privacy: .public): \(width, privacy: .public)x\(height, privacy: .public)")
        }
    }

    private func logDrop(kind: String) {
        lock.lock()
        var conversionCount: Int?
        var sampleCount: Int?
        switch kind {
        case "pixel-buffer-conversion":
            conversionDropCount += 1
            if conversionDropCount == 1 || conversionDropCount % 120 == 0 {
                conversionCount = conversionDropCount
            }
        default:
            sampleBufferDropCount += 1
            if sampleBufferDropCount == 1 || sampleBufferDropCount % 120 == 0 {
                sampleCount = sampleBufferDropCount
            }
        }
        lock.unlock()

        if let conversionCount {
            KVMLog.webrtc.error("GLKVM dropped WebRTC frame during pixel buffer conversion; count=\(conversionCount, privacy: .public)")
        }
        if let sampleCount {
            KVMLog.webrtc.error("GLKVM dropped WebRTC frame during sample buffer creation; count=\(sampleCount, privacy: .public)")
        }
    }

    private func makePixelBuffer(from buffer: RTCVideoFrameBuffer) -> CVPixelBuffer? {
        if let cvPixelBuffer = buffer as? RTCCVPixelBuffer {
            return cvPixelBuffer.pixelBuffer
        }

        return makePixelBuffer(from: buffer.toI420())
    }

    private func makePixelBuffer(from i420Buffer: RTCI420Buffer) -> CVPixelBuffer? {
        let width = Int(i420Buffer.width)
        let height = Int(i420Buffer.height)
        guard width > 0, height > 0 else { return nil }

        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var pixelBuffer: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard createStatus == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard
            let yDestination = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self),
            let uvDestination = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self)
        else { return nil }

        copyPlane(
            source: i420Buffer.dataY,
            sourceStride: Int(i420Buffer.strideY),
            destination: yDestination,
            destinationStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
            width: width,
            height: height
        )

        let chromaWidth = Int(i420Buffer.chromaWidth)
        let chromaHeight = Int(i420Buffer.chromaHeight)
        let uvDestinationStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let uSource = i420Buffer.dataU
        let vSource = i420Buffer.dataV
        let uStride = Int(i420Buffer.strideU)
        let vStride = Int(i420Buffer.strideV)

        for row in 0..<chromaHeight {
            let uRow = uSource.advanced(by: row * uStride)
            let vRow = vSource.advanced(by: row * vStride)
            let uvRow = uvDestination.advanced(by: row * uvDestinationStride)
            for column in 0..<chromaWidth {
                uvRow[column * 2] = uRow[column]
                uvRow[column * 2 + 1] = vRow[column]
            }
        }

        return pixelBuffer
    }

    private func copyPlane(
        source: UnsafePointer<UInt8>,
        sourceStride: Int,
        destination: UnsafeMutablePointer<UInt8>,
        destinationStride: Int,
        width: Int,
        height: Int
    ) {
        for row in 0..<height {
            let sourceRow = source.advanced(by: row * sourceStride)
            let destinationRow = destination.advanced(by: row * destinationStride)
            destinationRow.update(from: sourceRow, count: width)
        }
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, timestampNs: Int64) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(timestampNs), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr else { return nil }
        return sampleBuffer
    }

    private func markDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0,
            let attachment = CFArrayGetValueAtIndex(attachments, 0)
        else { return }

        let attachmentDictionary = unsafeBitCast(attachment, to: CFMutableDictionary.self)
        CFDictionarySetValue(
            attachmentDictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}
