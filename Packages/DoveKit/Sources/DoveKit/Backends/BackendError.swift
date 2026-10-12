import Foundation

public enum BackendError: Error, Sendable, Equatable, LocalizedError {
    case notImplemented
    case unsupportedSource(SourceKind)
    case unauthorized
    case rateLimited
    case notFound
    case http(status: Int)
    case api(message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notImplemented: "This backend is not implemented yet."
        case .unsupportedSource(let kind): "No configured backend accepts \(kind.rawValue) sources."
        case .unauthorized: "Invalid or expired API key."
        case .rateLimited: "Too many requests. Try again in a moment."
        case .notFound: "Item not found."
        case .http(let status): "Server returned HTTP \(status)."
        case .api(let message): message
        case .invalidResponse: "Unexpected response from server."
        }
    }
}
