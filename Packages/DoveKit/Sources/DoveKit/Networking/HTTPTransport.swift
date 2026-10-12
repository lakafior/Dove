import Foundation

/// Thin seam over URLSession so backends can be tested with canned responses.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackendError.invalidResponse }
        return (data, http)
    }
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
