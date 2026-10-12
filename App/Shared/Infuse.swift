import Foundation

/// Infuse plays any URL handed over with its x-callback scheme. Debrid links resolve on the first request.
enum Infuse {
    /// Only RFC 3986 unreserved characters stay literal. `URLQueryItem` leaves `+`, `/`, `?` and `:` as they are,
    /// and Infuse decodes `+` as a space, which breaks links whose file name has a `+` (the server answers 400).
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func playURL(for url: URL) -> URL? {
        guard let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "infuse://x-callback-url/play?url=\(encoded)")
    }
}
