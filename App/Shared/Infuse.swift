import Foundation

/// Infuse plays any URL handed over with its x-callback scheme. Debrid links resolve on the first request.
enum Infuse {
    /// Only RFC 3986 unreserved characters stay literal. `URLQueryItem` leaves `+`, `/`, `?` and `:` as they are,
    /// and Infuse decodes `+` as a space, which breaks links whose file name has a `+` (the server answers 400).
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func playURL(for url: URL) -> URL? {
        playURL(for: [(url, nil)])
    }

    /// Several `url`s play in order as a temporary playlist (Infuse 8.4.7+). `filename` gives Infuse a name to
    /// read the show and episode from ("Lost - S01E01.mkv") when the link's path does not (TorBox's uuids).
    static func playURL(for entries: [(url: URL, filename: String?)]) -> URL? {
        guard !entries.isEmpty else { return nil }
        var parameters: [String] = []
        for entry in entries {
            guard let url = encode(entry.url.absoluteString) else { return nil }
            parameters.append("url=\(url)")
            if let filename = entry.filename, let name = encode(filename) { parameters.append("filename=\(name)") }
        }
        return URL(string: "infuse://x-callback-url/play?" + parameters.joined(separator: "&"))
    }

    private static func encode(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: unreserved)
    }
}
