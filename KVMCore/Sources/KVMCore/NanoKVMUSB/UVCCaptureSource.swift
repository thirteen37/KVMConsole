#if os(macOS)
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation

public enum UVCCaptureError: Error, LocalizedError {
    case deviceNotFound(uniqueID: String)
    case cannotAddInput
    case cannotAddOutput
    case sessionRuntimeError(Error)

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound(let id):
            return "Could not find USB video capture device (uniqueID=\(id)). It may have been unplugged."
        case .cannotAddInput:
            return "AVCaptureSession refused the USB video device as an input."
        case .cannotAddOutput:
            return "AVCaptureSession refused the sample-buffer output."
        case .sessionRuntimeError(let error):
            return "Video capture failed: \(error.localizedDescription)"
        }
    }
}

/// Wraps an `AVCaptureSession` to drive a UVC composite (e.g. Sipeed NanoKVM-USB).
/// Sample buffers are forwarded directly into the shared `SampleBufferRenderCoordinator`
/// — UVC frames are already decoded, so there's no H.264 step.
@MainActor
public final class UVCCaptureSource: NSObject {
    public typealias VideoSizeHandler = @MainActor (CGSize?) -> Void
    public typealias ErrorHandler = @MainActor (Error) -> Void

    private nonisolated let renderCoordinator: SampleBufferRenderCoordinator
    private nonisolated let sampleQueue = DispatchQueue(
        label: "io.lyx.KVMConsole.UVCCaptureSource.samples",
        qos: .userInitiated
    )
    private let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?
    private var output: AVCaptureVideoDataOutput?
    private var observers: [NSObjectProtocol] = []

    public var onVideoSize: VideoSizeHandler?
    public var onRuntimeError: ErrorHandler?

    public private(set) var videoSize: CGSize?

    public init(renderCoordinator: SampleBufferRenderCoordinator) {
        self.renderCoordinator = renderCoordinator
    }

    public func start(deviceUniqueID: String) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceUniqueID) else {
            throw UVCCaptureError.deviceNotFound(uniqueID: deviceUniqueID)
        }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: sampleQueue)

        session.beginConfiguration()
        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw UVCCaptureError.cannotAddInput
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw UVCCaptureError.cannotAddOutput
        }
        session.addOutput(output)
        session.commitConfiguration()

        self.device = device
        self.input = input
        self.output = output

        installObservers()
        session.startRunning()
    }

    public func stop() {
        if session.isRunning {
            session.stopRunning()
        }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()

        session.beginConfiguration()
        if let input { session.removeInput(input) }
        if let output { session.removeOutput(output) }
        session.commitConfiguration()

        device = nil
        input = nil
        output = nil
        videoSize = nil
    }

    private func installObservers() {
        let runtimeError = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                ?? NSError(domain: AVFoundationErrorDomain, code: -1)
            MainActor.assumeIsolated {
                self?.onRuntimeError?(UVCCaptureError.sessionRuntimeError(error))
            }
        }
        observers.append(runtimeError)
    }

    fileprivate func updateVideoSize(_ size: CGSize?) {
        guard videoSize != size else { return }
        videoSize = size
        onVideoSize?(size)
    }

    nonisolated fileprivate static func videoSize(from sampleBuffer: CMSampleBuffer) -> CGSize? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        return CGSize(
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer)
        )
    }
}

extension UVCCaptureSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        renderCoordinator.enqueue(sampleBuffer)

        let size = Self.videoSize(from: sampleBuffer)
        Task { @MainActor [weak self] in
            self?.updateVideoSize(size)
        }
    }
}
#endif
