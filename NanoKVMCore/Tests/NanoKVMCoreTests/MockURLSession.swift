import Foundation
@testable import NanoKVMCore

/// Records the requests sent to it and replies with a queued list of canned responses.
/// Each canned response is consumed in order; running out fails the test.
final class MockURLSession: URLSessionProtocol, @unchecked Sendable {
    struct Canned: Sendable {
        let status: Int
        let body: Data
        init(status: Int = 200, body: Data) { self.status = status; self.body = body }
        init(status: Int = 200, json: String) { self.init(status: status, body: Data(json.utf8)) }
    }

    private let queueLock = DispatchQueue(label: "MockURLSession")
    private var queue: [Canned] = []
    private(set) var sent: [URLRequest] = []

    func enqueue(_ canned: Canned) {
        queueLock.sync {
            queue.append(canned)
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let canned = queueLock.sync {
            guard !queue.isEmpty else {
                fatalError("MockURLSession ran out of canned responses (request: \(request.url?.absoluteString ?? "?"))")
            }
            let canned = queue.removeFirst()
            sent.append(request)
            return canned
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: canned.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (canned.body, response)
    }
}
