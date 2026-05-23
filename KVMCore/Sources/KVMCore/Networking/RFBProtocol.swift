import Foundation

public enum RFBError: Error, LocalizedError, Equatable {
    case invalidProtocolVersion(String)
    case unsupportedProtocolVersion(String)
    case securityTypeUnavailable(RFBSecurityPreference, [RFBSecurityType])
    case authenticationFailed(String)
    case malformedMessage(String)
    case unsupportedEncoding(Int32)
    case timeout(String)
    case connectionClosed

    public var errorDescription: String? {
        switch self {
        case .invalidProtocolVersion(let version):
            return "Invalid RFB protocol version '\(version)'."
        case .unsupportedProtocolVersion(let version):
            return "Unsupported RFB protocol version '\(version)'."
        case .securityTypeUnavailable(let preference, let offered):
            let names = offered.map(\.displayName).joined(separator: ", ")
            return "The server does not offer \(preference.displayName) authentication. Offered: \(names.isEmpty ? "none" : names)."
        case .authenticationFailed(let message):
            return "RFB authentication failed: \(message)"
        case .malformedMessage(let message):
            return "Malformed RFB message: \(message)"
        case .unsupportedEncoding(let encoding):
            return "Unsupported RFB encoding \(encoding)."
        case .timeout(let operation):
            return "Timed out while \(operation)."
        case .connectionClosed:
            return "The RFB connection closed."
        }
    }
}

public struct RFBProtocolVersion: Equatable, Sendable {
    public let major: Int
    public let minor: Int

    public static let v3_8 = RFBProtocolVersion(major: 3, minor: 8)

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public init(greeting: Data) throws {
        guard greeting.count == 12, let text = String(data: greeting, encoding: .ascii) else {
            throw RFBError.invalidProtocolVersion("<non-ascii>")
        }
        guard text.hasPrefix("RFB "), text.hasSuffix("\n") else {
            throw RFBError.invalidProtocolVersion(text)
        }
        let version = text.dropFirst(4).dropLast()
        let parts = version.split(separator: ".")
        guard
            parts.count == 2,
            let major = Int(parts[0]),
            let minor = Int(parts[1])
        else {
            throw RFBError.invalidProtocolVersion(text)
        }
        self.major = major
        self.minor = minor
    }

    public var wireData: Data {
        Data(String(format: "RFB %03d.%03d\n", major, minor).utf8)
    }
}

public enum RFBSecurityType: UInt8, Equatable, Sendable {
    case invalid = 0
    case none = 1
    case vncAuthentication = 2
    case appleDiffieHellman30 = 30
    case appleSecurity33 = 33
    case appleSecurity35 = 35
    case appleSecurity36 = 36

    public var displayName: String {
        switch self {
        case .invalid: return "Invalid"
        case .none: return "None"
        case .vncAuthentication: return "VNC password"
        case .appleDiffieHellman30:
            return "Apple Diffie-Hellman"
        case .appleSecurity33, .appleSecurity35, .appleSecurity36:
            return "Apple security type \(rawValue)"
        }
    }

    public var isAppleDiffieHellman: Bool {
        switch self {
        case .appleDiffieHellman30:
            return true
        default:
            return false
        }
    }
}

public enum RFBSecurityPreference: Equatable, Sendable {
    case appleScreenSharing
    case vnc

    public var displayName: String {
        switch self {
        case .appleScreenSharing: return "Apple Screen Sharing"
        case .vnc: return "VNC password"
        }
    }

    public func choose(from offered: [RFBSecurityType]) throws -> RFBSecurityType {
        switch self {
        case .appleScreenSharing:
            for type in [
                RFBSecurityType.appleDiffieHellman30,
                .vncAuthentication
            ] {
                if offered.contains(type) { return type }
            }
        case .vnc:
            if offered.contains(.vncAuthentication) { return .vncAuthentication }
        }
        throw RFBError.securityTypeUnavailable(self, offered)
    }
}

public struct RFBSessionProfile: Equatable, Sendable {
    public let securityPreference: RFBSecurityPreference
    public let inputEchoUpdatePolicy: RFBInputEchoUpdatePolicy

    public static let appleScreenSharing = RFBSessionProfile(
        securityPreference: .appleScreenSharing,
        inputEchoUpdatePolicy: .keyboard(minimumInterval: 0.05, trigger: .keyUp)
    )

    public static let vnc = RFBSessionProfile(
        securityPreference: .vnc
    )

    public init(
        securityPreference: RFBSecurityPreference,
        inputEchoUpdatePolicy: RFBInputEchoUpdatePolicy = .disabled
    ) {
        self.securityPreference = securityPreference
        self.inputEchoUpdatePolicy = inputEchoUpdatePolicy
    }
}

public enum RFBInputEchoUpdatePolicy: Equatable, Sendable {
    case disabled
    case keyboard(minimumInterval: TimeInterval, trigger: RFBInputEchoUpdateTrigger)
}

public enum RFBInputEchoUpdateTrigger: Equatable, Sendable {
    case keyDown
    case keyUp
}

public struct RFBPixelFormat: Equatable, Sendable {
    public var bitsPerPixel: UInt8
    public var depth: UInt8
    public var bigEndianFlag: UInt8
    public var trueColorFlag: UInt8
    public var redMax: UInt16
    public var greenMax: UInt16
    public var blueMax: UInt16
    public var redShift: UInt8
    public var greenShift: UInt8
    public var blueShift: UInt8

    public static let bgra = RFBPixelFormat(
        bitsPerPixel: 32,
        depth: 24,
        bigEndianFlag: 0,
        trueColorFlag: 1,
        redMax: 255,
        greenMax: 255,
        blueMax: 255,
        redShift: 16,
        greenShift: 8,
        blueShift: 0
    )

    public var wireData: Data {
        var writer = RFBByteWriter()
        writer.writeUInt8(bitsPerPixel)
        writer.writeUInt8(depth)
        writer.writeUInt8(bigEndianFlag)
        writer.writeUInt8(trueColorFlag)
        writer.writeUInt16(redMax)
        writer.writeUInt16(greenMax)
        writer.writeUInt16(blueMax)
        writer.writeUInt8(redShift)
        writer.writeUInt8(greenShift)
        writer.writeUInt8(blueShift)
        writer.writePadding(count: 3)
        return writer.data
    }

    public init(
        bitsPerPixel: UInt8,
        depth: UInt8,
        bigEndianFlag: UInt8,
        trueColorFlag: UInt8,
        redMax: UInt16,
        greenMax: UInt16,
        blueMax: UInt16,
        redShift: UInt8,
        greenShift: UInt8,
        blueShift: UInt8
    ) {
        self.bitsPerPixel = bitsPerPixel
        self.depth = depth
        self.bigEndianFlag = bigEndianFlag
        self.trueColorFlag = trueColorFlag
        self.redMax = redMax
        self.greenMax = greenMax
        self.blueMax = blueMax
        self.redShift = redShift
        self.greenShift = greenShift
        self.blueShift = blueShift
    }

    public init(reader: inout RFBByteReader) throws {
        bitsPerPixel = try reader.readUInt8()
        depth = try reader.readUInt8()
        bigEndianFlag = try reader.readUInt8()
        trueColorFlag = try reader.readUInt8()
        redMax = try reader.readUInt16()
        greenMax = try reader.readUInt16()
        blueMax = try reader.readUInt16()
        redShift = try reader.readUInt8()
        greenShift = try reader.readUInt8()
        blueShift = try reader.readUInt8()
        try reader.skip(3)
    }
}

public enum RFBEncoding: Int32, Sendable {
    case raw = 0
    case copyRect = 1
    case zrle = 16
    case desktopSize = -223
    case lastRect = -224
    case fence = -312
}

public enum RFBClientMessage {
    private static let fenceRequestFlag: UInt32 = 1 << 31

    public static func setPixelFormat(_ pixelFormat: RFBPixelFormat = .bgra) -> Data {
        var writer = RFBByteWriter()
        writer.writeUInt8(0)
        writer.writePadding(count: 3)
        writer.writeData(pixelFormat.wireData)
        return writer.data
    }

    public static func setEncodings(_ encodings: [RFBEncoding]) -> Data {
        var writer = RFBByteWriter()
        writer.writeUInt8(2)
        writer.writePadding(count: 1)
        writer.writeUInt16(UInt16(encodings.count))
        for encoding in encodings {
            writer.writeInt32(encoding.rawValue)
        }
        return writer.data
    }

    public static func framebufferUpdateRequest(incremental: Bool, x: UInt16, y: UInt16, width: UInt16, height: UInt16) -> Data {
        var writer = RFBByteWriter()
        writer.writeUInt8(3)
        writer.writeUInt8(incremental ? 1 : 0)
        writer.writeUInt16(x)
        writer.writeUInt16(y)
        writer.writeUInt16(width)
        writer.writeUInt16(height)
        return writer.data
    }

    public static func keyEvent(down: Bool, keysym: UInt32) -> Data {
        var writer = RFBByteWriter()
        writer.writeUInt8(4)
        writer.writeUInt8(down ? 1 : 0)
        writer.writePadding(count: 2)
        writer.writeUInt32(keysym)
        return writer.data
    }

    public static func pointerEvent(buttonMask: UInt8, x: UInt16, y: UInt16) -> Data {
        var writer = RFBByteWriter()
        writer.writeUInt8(5)
        writer.writeUInt8(buttonMask)
        writer.writeUInt16(x)
        writer.writeUInt16(y)
        return writer.data
    }

    public static func clientFenceResponse(flags: UInt32, payload: Data) throws -> Data {
        guard payload.count <= 64 else {
            throw RFBError.malformedMessage("RFB fence payload is too large")
        }

        var writer = RFBByteWriter()
        writer.writeUInt8(248)
        writer.writePadding(count: 3)
        writer.writeUInt32(flags & ~fenceRequestFlag)
        writer.writeUInt8(UInt8(payload.count))
        writer.writeData(payload)
        return writer.data
    }
}

public struct RFBRectangle: Equatable, Sendable {
    public var x: UInt16
    public var y: UInt16
    public var width: UInt16
    public var height: UInt16
    public var encoding: Int32

    public init(x: UInt16, y: UInt16, width: UInt16, height: UInt16, encoding: Int32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.encoding = encoding
    }

    public init(reader: inout RFBByteReader) throws {
        x = try reader.readUInt16()
        y = try reader.readUInt16()
        width = try reader.readUInt16()
        height = try reader.readUInt16()
        encoding = try reader.readInt32()
    }
}

public struct RFBByteReader {
    private let bytes: Data
    private var offset: Int

    public init(_ data: Data) {
        self.bytes = data
        self.offset = data.startIndex
    }

    public var remainingCount: Int { bytes.endIndex - offset }
    public var isAtEnd: Bool { remainingCount == 0 }

    public mutating func readUInt8() throws -> UInt8 {
        guard remainingCount >= 1 else { throw RFBError.malformedMessage("expected UInt8") }
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func readUInt16() throws -> UInt16 {
        let high = UInt16(try readUInt8())
        let low = UInt16(try readUInt8())
        return (high << 8) | low
    }

    public mutating func readUInt32() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            value = (value << 8) | UInt32(try readUInt8())
        }
        return value
    }

    public mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    public mutating func readData(count: Int) throws -> Data {
        guard count >= 0, remainingCount >= count else {
            throw RFBError.malformedMessage("expected \(count) bytes")
        }
        let start = offset
        offset += count
        return bytes[start..<offset]
    }

    public mutating func readString(count: Int) throws -> String {
        let data = try readData(count: count)
        guard let string = String(data: data, encoding: .utf8) else {
            throw RFBError.malformedMessage("invalid UTF-8 string")
        }
        return string
    }

    public mutating func skip(_ count: Int) throws {
        guard count >= 0, remainingCount >= count else {
            throw RFBError.malformedMessage("expected \(count) bytes")
        }
        offset += count
    }
}

public struct RFBByteWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func writeUInt8(_ value: UInt8) {
        data.append(value)
    }

    public mutating func writeUInt16(_ value: UInt16) {
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    public mutating func writeUInt32(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    public mutating func writeInt32(_ value: Int32) {
        writeUInt32(UInt32(bitPattern: value))
    }

    public mutating func writePadding(count: Int) {
        data.append(contentsOf: repeatElement(UInt8(0), count: count))
    }

    public mutating func writeData(_ value: Data) {
        data.append(value)
    }
}
