import Foundation

/// Infuse plays any URL handed over with its x-callback scheme. Debrid links resolve on the first request.
enum Infuse {
    static func playURL(for url: URL) -> URL? {
        var components = URLComponents(string: "infuse://x-callback-url/play")!
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return components.url
    }
}
