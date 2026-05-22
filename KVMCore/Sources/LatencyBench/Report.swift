#if os(macOS)
import Foundation
import KVMCore

/// Aggregates video frame samples and writes JSON + CSV reports.
struct Report {
    let device: Device
    let metric: String
    let metadata: [String: AnyEncodable]
    let frameSamples: [VideoLatencyRunner.FrameSample]

    init(
        device: Device,
        metric: String,
        metadata: [String: AnyEncodable],
        frameSamples: [VideoLatencyRunner.FrameSample] = []
    ) {
        self.device = device
        self.metric = metric
        self.metadata = metadata
        self.frameSamples = frameSamples
    }

    func write(to directory: URL) throws -> (json: URL, csv: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter.bench.string(from: Date())
        let safeName = device.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let stem = "\(timestamp)-\(metric)-\(safeName)"

        let jsonURL = directory.appendingPathComponent("\(stem).json")
        let csvURL = directory.appendingPathComponent("\(stem).csv")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let payload = JSONPayload(
            schemaVersion: 1,
            ranAt: Date(),
            device: .init(
                id: device.id.uuidString,
                name: device.name,
                host: device.host,
                port: device.port,
                kvmType: device.kvmType.rawValue,
                kvmTypeDisplay: device.kvmType.displayName
            ),
            metric: metric,
            metadata: metadata,
            samples: frameSamples.map(SampleRow.init),
            summary: SummarySection(samples: frameSamples)
        )
        try encoder.encode(payload).write(to: jsonURL, options: .atomic)

        var csv = "frameIndex,wireToEnqueueMs,enqueueToPresentedMs,wireToPresentedMs,interFrameMs\n"
        for sample in frameSamples {
            csv += "\(sample.frameIndex),"
            csv += sample.wireToEnqueueMs.map { String(format: "%.3f", $0) } ?? ""
            csv += ","
            csv += String(format: "%.3f", sample.enqueueToPresentedMs)
            csv += ","
            csv += sample.wireToPresentedMs.map { String(format: "%.3f", $0) } ?? ""
            csv += ","
            csv += sample.interFrameMs.map { String(format: "%.3f", $0) } ?? ""
            csv += "\n"
        }
        try Data(csv.utf8).write(to: csvURL, options: .atomic)

        return (jsonURL, csvURL)
    }

    func summaryDescription() -> String {
        guard !frameSamples.isEmpty else { return "No frames captured." }
        let summary = SummarySection(samples: frameSamples)
        var lines = ["Frames captured: \(frameSamples.count)"]
        for stage in summary.stages {
            lines.append(String(
                format: "  %-22@ min=%.1f  p50=%.1f  p95=%.1f  p99=%.1f  max=%.1f  mean=%.1f  n=%d",
                stage.name as NSString,
                stage.min, stage.p50, stage.p95, stage.p99, stage.max, stage.mean, stage.count
            ))
        }
        return lines.joined(separator: "\n")
    }
}

struct JSONPayload: Encodable {
    let schemaVersion: Int
    let ranAt: Date
    let device: DeviceSection
    let metric: String
    let metadata: [String: AnyEncodable]
    let samples: [SampleRow]
    let summary: SummarySection

    struct DeviceSection: Encodable {
        let id: String
        let name: String
        let host: String
        let port: Int
        let kvmType: String
        let kvmTypeDisplay: String
    }
}

struct SampleRow: Encodable {
    let frameIndex: Int
    let wireToEnqueueMs: Double?
    let enqueueToPresentedMs: Double
    let wireToPresentedMs: Double?
    let interFrameMs: Double?

    init(_ sample: VideoLatencyRunner.FrameSample) {
        self.frameIndex = sample.frameIndex
        self.wireToEnqueueMs = sample.wireToEnqueueMs
        self.enqueueToPresentedMs = sample.enqueueToPresentedMs
        self.wireToPresentedMs = sample.wireToPresentedMs
        self.interFrameMs = sample.interFrameMs
    }
}

struct SummarySection: Encodable {
    struct Stage: Encodable {
        let name: String
        let count: Int
        let min: Double
        let p50: Double
        let p95: Double
        let p99: Double
        let max: Double
        let mean: Double
    }

    let stages: [Stage]

    init(samples: [VideoLatencyRunner.FrameSample]) {
        let wireToEnqueue = samples.compactMap { $0.wireToEnqueueMs }
        let enqueueToPresented = samples.map { $0.enqueueToPresentedMs }
        let wireToPresented = samples.compactMap { $0.wireToPresentedMs }
        let interFrame = samples.compactMap { $0.interFrameMs }
        self.stages = [
            Stage.make("wireToEnqueueMs", values: wireToEnqueue),
            Stage.make("enqueueToPresentedMs", values: enqueueToPresented),
            Stage.make("wireToPresentedMs", values: wireToPresented),
            Stage.make("interFrameMs", values: interFrame)
        ]
    }
}

extension SummarySection.Stage {
    static func make(_ name: String, values: [Double]) -> SummarySection.Stage {
        guard !values.isEmpty else {
            return .init(name: name, count: 0, min: 0, p50: 0, p95: 0, p99: 0, max: 0, mean: 0)
        }
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double {
            let rank = Swift.max(0.0, Swift.min(Double(sorted.count - 1), p * Double(sorted.count - 1)))
            let lo = Int(rank.rounded(.down))
            let hi = Int(rank.rounded(.up))
            if lo == hi { return sorted[lo] }
            let fraction = rank - Double(lo)
            return sorted[lo] + (sorted[hi] - sorted[lo]) * fraction
        }
        let mean = values.reduce(0, +) / Double(values.count)
        return .init(
            name: name,
            count: values.count,
            min: sorted.first ?? 0,
            p50: percentile(0.5),
            p95: percentile(0.95),
            p99: percentile(0.99),
            max: sorted.last ?? 0,
            mean: mean
        )
    }
}

struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        self._encode = { encoder in
            try value.encode(to: encoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let bench: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

enum DefaultReportLocation {
    static func directory() -> URL {
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd)
            .appendingPathComponent("Scripts", isDirectory: true)
            .appendingPathComponent("latency-reports", isDirectory: true)
    }
}
#endif
