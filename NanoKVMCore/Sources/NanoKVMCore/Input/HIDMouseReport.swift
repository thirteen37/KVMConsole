import CoreGraphics
import Foundation

public struct HIDMouseAbsoluteReport: Equatable, Sendable {
    public var buttons: UInt8
    public var x: UInt16
    public var y: UInt16
    public var wheel: Int8

    public init(buttons: UInt8 = 0, x: UInt16 = 1, y: UInt16 = 1, wheel: Int8 = 0) {
        self.buttons = buttons
        self.x = x
        self.y = y
        self.wheel = wheel
    }

    public var reportBytes: [UInt8] {
        [
            buttons,
            UInt8(x & 0x00ff),
            UInt8((x & 0xff00) >> 8),
            UInt8(y & 0x00ff),
            UInt8((y & 0xff00) >> 8),
            UInt8(bitPattern: wheel),
        ]
    }

    public var nanoKVMMessageData: Data {
        Data([0x02] + reportBytes)
    }
}

public final class HIDMouseAbsoluteReportBuilder {
    private var buttons: UInt8 = 0
    private var x: UInt16 = 1
    private var y: UInt16 = 1

    public init() {}

    public func move(x: UInt16, y: UInt16) -> HIDMouseAbsoluteReport {
        self.x = x
        self.y = y
        return currentReport()
    }

    public func buttonDown(buttonNumber: Int, x: UInt16, y: UInt16) -> HIDMouseAbsoluteReport {
        self.x = x
        self.y = y
        if let bit = Self.buttonBit(for: buttonNumber) {
            buttons |= bit
        }
        return currentReport()
    }

    public func buttonUp(buttonNumber: Int, x: UInt16, y: UInt16) -> HIDMouseAbsoluteReport {
        self.x = x
        self.y = y
        if let bit = Self.buttonBit(for: buttonNumber) {
            buttons &= ~bit
        }
        return currentReport()
    }

    public func wheel(_ direction: Int8, x: UInt16, y: UInt16) -> HIDMouseAbsoluteReport {
        self.x = x
        self.y = y
        return currentReport(wheel: direction)
    }

    public func reset() -> HIDMouseAbsoluteReport {
        buttons = 0
        return currentReport()
    }

    private func currentReport(wheel: Int8 = 0) -> HIDMouseAbsoluteReport {
        HIDMouseAbsoluteReport(buttons: buttons, x: x, y: y, wheel: wheel)
    }

    public static func buttonBit(for buttonNumber: Int) -> UInt8? {
        switch buttonNumber {
        case 0: return 0x01
        case 1: return 0x02
        case 2: return 0x04
        case 3: return 0x08
        case 4: return 0x10
        default: return nil
        }
    }
}

public enum MouseCoordinateMapper {
    public static func absolutePoint(clientPoint: CGPoint, bounds: CGRect, videoSize: CGSize?) -> (x: UInt16, y: UInt16) {
        guard bounds.width > 0, bounds.height > 0 else {
            return (1, 1)
        }

        let mediaRect = aspectFitRect(for: videoSize, in: bounds)
        let normalizedX = clamp((clientPoint.x - mediaRect.minX) / mediaRect.width)
        let normalizedY = clamp((clientPoint.y - mediaRect.minY) / mediaRect.height)

        return (
            UInt16(floor(32_767 * normalizedX) + 1),
            UInt16(floor(32_767 * normalizedY) + 1)
        )
    }

    private static func aspectFitRect(for videoSize: CGSize?, in bounds: CGRect) -> CGRect {
        guard
            let videoSize,
            videoSize.width > 0,
            videoSize.height > 0
        else {
            return bounds
        }

        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let width = videoSize.width * scale
        let height = videoSize.height * scale
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}

public struct MouseScrollAccumulator {
    public static let pointsPerNotch: CGFloat = 16

    private var accumulator: CGFloat = 0

    public init() {}

    public mutating func notches(for scrollingDeltaY: CGFloat, isInverted: Bool) -> Int8? {
        guard scrollingDeltaY != 0 else { return nil }
        accumulator += isInverted ? -scrollingDeltaY : scrollingDeltaY
        let raw = (accumulator / Self.pointsPerNotch).rounded(.towardZero)
        guard raw != 0 else { return nil }
        accumulator -= raw * Self.pointsPerNotch
        let clamped = max(CGFloat(Int8.min), min(CGFloat(Int8.max), raw))
        return Int8(clamped)
    }

    public mutating func reset() {
        accumulator = 0
    }
}
