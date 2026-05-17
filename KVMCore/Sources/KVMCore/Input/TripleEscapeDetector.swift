import Foundation

public struct TripleEscapeDetector: Equatable, Sendable {
    public static let triggerCount = 3
    public static let window: TimeInterval = 1.5

    private var timestamps: [Date] = []

    public init() {}

    public mutating func register(at timestamp: Date) -> Bool {
        timestamps.append(timestamp)
        let cutoff = timestamp.addingTimeInterval(-Self.window)
        timestamps.removeAll { $0 < cutoff }
        return timestamps.count >= Self.triggerCount
    }

    public mutating func reset() {
        timestamps.removeAll()
    }
}
