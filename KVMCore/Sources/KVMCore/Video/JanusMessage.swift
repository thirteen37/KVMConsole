import Foundation

public enum JanusMessage {
    public static func create(transaction: String) -> [String: Any] {
        ["janus": "create", "transaction": transaction]
    }

    public static func attach(sessionID: Int64, transaction: String) -> [String: Any] {
        [
            "janus": "attach",
            "plugin": "janus.plugin.ustreamer",
            "session_id": sessionID,
            "transaction": transaction,
        ]
    }

    public static func features(sessionID: Int64, handleID: Int64, transaction: String) -> [String: Any] {
        message(
            sessionID: sessionID,
            handleID: handleID,
            transaction: transaction,
            body: ["request": "features"]
        )
    }

    public static func watch(sessionID: Int64, handleID: Int64, transaction: String) -> [String: Any] {
        message(
            sessionID: sessionID,
            handleID: handleID,
            transaction: transaction,
            body: [
                "request": "watch",
                "params": [
                    "orientation": 0,
                    "audio": false,
                    "video": true,
                    "mic": false,
                    "camera": false,
                    "video_format": 0,
                ],
            ]
        )
    }

    public static func start(
        sessionID: Int64,
        handleID: Int64,
        transaction: String,
        jsep: JanusJSEP
    ) -> [String: Any] {
        var payload = message(
            sessionID: sessionID,
            handleID: handleID,
            transaction: transaction,
            body: ["request": "start"]
        )
        payload["jsep"] = ["type": jsep.type, "sdp": jsep.sdp]
        return payload
    }

    public static func keyRequired(sessionID: Int64, handleID: Int64, transaction: String) -> [String: Any] {
        message(
            sessionID: sessionID,
            handleID: handleID,
            transaction: transaction,
            body: ["request": "key_required"]
        )
    }

    public static func trickle(
        sessionID: Int64,
        handleID: Int64,
        transaction: String,
        candidate: JanusCandidate
    ) -> [String: Any] {
        [
            "janus": "trickle",
            "session_id": sessionID,
            "handle_id": handleID,
            "transaction": transaction,
            "candidate": candidate.dictionary,
        ]
    }

    public static func keepAlive(sessionID: Int64, transaction: String) -> [String: Any] {
        [
            "janus": "keepalive",
            "session_id": sessionID,
            "transaction": transaction,
        ]
    }

    public static func destroy(sessionID: Int64, transaction: String) -> [String: Any] {
        [
            "janus": "destroy",
            "session_id": sessionID,
            "transaction": transaction,
        ]
    }

    private static func message(
        sessionID: Int64,
        handleID: Int64,
        transaction: String,
        body: [String: Any]
    ) -> [String: Any] {
        [
            "janus": "message",
            "session_id": sessionID,
            "handle_id": handleID,
            "transaction": transaction,
            "body": body,
        ]
    }
}

public struct JanusJSEP: Codable, Equatable, Sendable {
    public let type: String
    public let sdp: String

    public init(type: String, sdp: String) {
        self.type = type
        self.sdp = sdp
    }
}

public struct JanusCandidate: Codable, Equatable, Sendable {
    public let candidate: String?
    public let sdpMid: String?
    public let sdpMLineIndex: Int32?
    public let completed: Bool?

    public init(candidate: String, sdpMid: String?, sdpMLineIndex: Int32) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.completed = nil
    }

    public init(completed: Bool) {
        self.candidate = nil
        self.sdpMid = nil
        self.sdpMLineIndex = nil
        self.completed = completed
    }

    private enum CodingKeys: String, CodingKey {
        case candidate
        case sdpMid
        case sdpMLineIndex
        case completed
    }

    public var dictionary: [String: Any] {
        if let completed {
            return ["completed": completed]
        }

        var payload: [String: Any] = [:]
        if let candidate {
            payload["candidate"] = candidate
        }
        if let sdpMid {
            payload["sdpMid"] = sdpMid
        }
        if let sdpMLineIndex {
            payload["sdpMLineIndex"] = sdpMLineIndex
        }
        return payload
    }
}

public struct JanusResponse: Decodable, Equatable, Sendable {
    public struct DataPayload: Decodable, Equatable, Sendable {
        public let id: Int64?
    }

    public struct PluginData: Decodable, Equatable, Sendable {
        public let plugin: String?
        public let data: UStreamerData?
    }

    public struct UStreamerData: Decodable, Equatable, Sendable {
        public let result: Result?
        public let errorCode: Int?
        public let error: String?

        private enum CodingKeys: String, CodingKey {
            case result
            case errorCode = "error_code"
            case error
        }
    }

    public struct Result: Decodable, Equatable, Sendable {
        public let status: String?
        public let features: Features?
    }

    public struct Features: Decodable, Equatable, Sendable {
        public let ice: ICE?
    }

    public struct ICE: Decodable, Equatable, Sendable {
        public let url: String?
    }

    public let janus: String
    public let transaction: String?
    public let sessionID: Int64?
    public let sender: Int64?
    public let data: DataPayload?
    public let pluginData: PluginData?
    public let jsep: JanusJSEP?
    public let candidate: JanusCandidate?

    private enum CodingKeys: String, CodingKey {
        case janus
        case transaction
        case sessionID = "session_id"
        case sender
        case data
        case pluginData = "plugindata"
        case jsep
        case candidate
    }

    var logDescription: String {
        var parts = ["janus=\(janus)"]
        if let transaction {
            parts.append("transaction=\(transaction)")
        }
        if let id = data?.id {
            parts.append("id=\(id)")
        }
        if let status = pluginData?.data?.result?.status {
            parts.append("status=\(status)")
        }
        if let errorCode = pluginData?.data?.errorCode {
            parts.append("error_code=\(errorCode)")
        }
        if let error = pluginData?.data?.error {
            parts.append("error=\(error)")
        }
        if let jsep {
            parts.append("jsep=\(jsep.type)")
        }
        if candidate != nil {
            parts.append("candidate=true")
        }
        return parts.joined(separator: " ")
    }
}
