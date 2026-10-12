import Foundation
import os

/// Thin seam over URLSession so backends can be tested with canned responses.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // Never log queries (TorBox `token=`) or headers (bearer tokens). Paths are private too:
        // Stremio addon and stream URLs embed tokens and encoded configs in the path.
        let method = request.httpMethod ?? "GET"
        let host = request.url?.host() ?? ""
        let path = request.url?.path() ?? ""
        let start = ContinuousClock.now
        do {
            let (data, response) = try await data(for: request)
            guard let http = response as? HTTPURLResponse else { throw BackendError.invalidResponse }
            HTTPLog.logger.debug(
                "\(method, privacy: .public) \(host, privacy: .public)\(path, privacy: .private) → \(http.statusCode) in \(ContinuousClock.now - start, privacy: .public)"
            )
            return (data, http)
        } catch {
            HTTPLog.logger.error(
                "\(method, privacy: .public) \(host, privacy: .public)\(path, privacy: .private) failed: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }
}

enum HTTPLog {
    static let logger = Logger(subsystem: "net.smigi.dove", category: "http")
}

extension HTTPURLResponse {
    /// Maps common failure status codes to `BackendError`. Returns nil for 2xx.
    var backendError: BackendError? {
        switch statusCode {
        case 200..<300: nil
        case 401, 403: .unauthorized
        case 404: .notFound
        case 429: .rateLimited
        default: .http(status: statusCode)
        }
    }
}
