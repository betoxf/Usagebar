//
//  ProviderHTTP.swift
//  JustaUsageBar
//
//  Sends provider requests without leaving a connection open between polls.
//  An idle HTTP/2 or HTTP/3 connection keeps waking the process for keepalives
//  and network-path updates, which costs more than a new handshake per poll.
//

import Foundation

@ProviderActor
enum ProviderHTTP {
    private static var session: URLSession?
    private static var requestsInFlight = 0

    static func data(for request: URLRequest, timeout: TimeInterval? = nil) async throws -> (Data, URLResponse) {
        var request = request
        if let timeout { request.timeoutInterval = timeout }

        // Requests that overlap share one session; the last to finish closes it.
        let session = session ?? makeSession()
        self.session = session
        requestsInFlight += 1
        defer {
            requestsInFlight -= 1
            if requestsInFlight == 0 {
                session.finishTasksAndInvalidate()
                self.session = nil
            }
        }
        return try await session.data(for: request)
    }

    private static func makeSession() -> URLSession {
        // Every provider authenticates with explicit headers, so nothing needs a
        // cookie jar or a response cache on disk.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }
}
