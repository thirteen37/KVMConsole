@preconcurrency import CoreMedia
import Foundation

/// Attaches and reads a wire-arrival host-clock timestamp on a `CMSampleBuffer`.
/// The attachment is consumed only by the `LatencyBench` executable; production
/// rendering code never reads it.
public enum SampleBufferLatencyTag {
    nonisolated(unsafe) public static let wireArrivalHostTimeKey: CFString =
        "io.lyx.LatencyBench.wireArrivalHostTime" as CFString

    public static func attachWireArrivalHostTime(_ time: CMTime, to sampleBuffer: CMSampleBuffer) {
        let dict: [String: Any] = [
            "value": Int64(time.value),
            "timescale": Int32(time.timescale),
            "flags": UInt32(time.flags.rawValue),
            "epoch": Int64(time.epoch)
        ]
        CMSetAttachment(
            sampleBuffer,
            key: wireArrivalHostTimeKey,
            value: dict as CFDictionary,
            attachmentMode: kCMAttachmentMode_ShouldNotPropagate
        )
    }

    public static func wireArrivalHostTime(of sampleBuffer: CMSampleBuffer) -> CMTime? {
        var mode: CMAttachmentMode = 0
        guard
            let raw = CMGetAttachment(sampleBuffer, key: wireArrivalHostTimeKey, attachmentModeOut: &mode),
            let dict = raw as? [String: Any],
            let value = dict["value"] as? Int64,
            let timescale = dict["timescale"] as? Int32,
            let flagsRaw = dict["flags"] as? UInt32
        else {
            return nil
        }
        let epoch = (dict["epoch"] as? Int64) ?? 0
        return CMTime(
            value: CMTimeValue(value),
            timescale: CMTimeScale(timescale),
            flags: CMTimeFlags(rawValue: flagsRaw),
            epoch: CMTimeEpoch(epoch)
        )
    }
}
