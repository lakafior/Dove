import Foundation

/// Turns free text from the "smart field", the clipboard or the share extension into a `Source`.
public enum SourceDetector {
    public static func detect(_ raw: String) -> Source? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.lowercased().hasPrefix("magnet:?") {
            return .magnet(text)
        }
        if isInfoHash(text) {
            return .magnet("magnet:?xt=urn:btih:\(text.lowercased())")
        }

        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }

        let path = url.path.lowercased()
        if path.hasSuffix(".torrent") {
            return .torrentURL(url)
        }
        if path.hasSuffix(".nzb") || isNewznabGet(url) {
            return .nzbURL(url)
        }
        return .hosterURL(url)
    }

    /// 40-character hex BitTorrent v1 info hash.
    static func isInfoHash(_ text: String) -> Bool {
        text.count == 40 && text.allSatisfy(\.isHexDigit)
    }

    /// Newznab download links look like `.../api?t=get&id=...&apikey=...`.
    static func isNewznabGet(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { $0.name.lowercased() == "t" && $0.value?.lowercased() == "get" }
    }
}
