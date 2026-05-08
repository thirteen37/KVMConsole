import Foundation
@testable import NanoKVM

/// Records the requests sent to it and replies with a queued list of canned responses.
/// Each canned response is consumed in order; running out fails the test.
final class MockURLSession: URLSessionProtocol, @unchecked Sendable {
    struct Canned: Sendable {
        let status: Int
        let body: Data
        init(status: Int = 200, body: Data) { self.status = status; self.body = body }
        init(status: Int = 200, json: String) { self.init(status: status, body: Data(json.utf8)) }
    }

    private let lock = NSLock()
    private var queue: [Canned] = []
    private(set) var sent: [URLRequest] = []

    func enqueue(_ canned: Canned) {
        lock.lock(); defer { lock.unlock() }
        queue.append(canned)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        guard !queue.isEmpty else {
            lock.unlock()
            fatalError("MockURLSession ran out of canned responses (request: \(request.url?.absoluteString ?? "?"))")
        }
        let canned = queue.removeFirst()
        sent.append(request)
        lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: canned.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (canned.body, response)
    }
}
