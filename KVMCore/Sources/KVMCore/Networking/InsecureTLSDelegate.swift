import Foundation

public final class InsecureTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let allowsInsecureTLS: Bool

    public init(allowsInsecureTLS: Bool) {
        self.allowsInsecureTLS = allowsInsecureTLS
        super.init()
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard
            allowsInsecureTLS,
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

