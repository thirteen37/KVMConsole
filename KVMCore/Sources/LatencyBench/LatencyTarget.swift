#if os(macOS)
@preconcurrency import CoreMedia
import CoreGraphics
import Foundation
import KVMCore

/// Bench-only abstraction over a live KVM session for measuring latency.
///
/// Each adapter wraps a production session (or session client) and emits the
/// sample buffers it produces through a single AsyncStream so the runner can
/// timestamp them uniformly.
@MainActor
protocol LatencyTarget: AnyObject {
    /// Connects and begins streaming. Returns once the first video size is known.
    func connect() async throws

    /// Closes the connection and any background tasks.
    func disconnect() async

    /// A stream of sample buffers produced by the session. Each buffer carries
    /// a wire-arrival timestamp attachment (see `SampleBufferLatencyTag`).
    var sampleBuffers: AsyncStream<CMSampleBuffer> { get }

    /// The framebuffer / video size, once known.
    var framebufferSize: CGSize? { get async }

    /// Sends an HID keyboard report.
    func sendKeyboardReport(_ report: HIDKeyboardReport) async

    /// Sends an HID absolute mouse report.
    func sendMouseReport(_ report: HIDMouseAbsoluteReport) async

    /// Human-readable name for log lines and report metadata.
    var displayLabel: String { get }
}
#endif
