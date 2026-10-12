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

    /// The first source anywhere in a longer text (a chat message, a web page excerpt): a magnet,
    /// then a link Dove can use, then a bare info hash.
    public static func firstSource(in text: String) -> Source? {
        if let source = detect(text) { return source }
        if let range = text.range(of: #"magnet:\?[^\s"'<>]+"#, options: [.regularExpression, .caseInsensitive]) {
            return .magnet(String(text[range]))
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                if let url = match.url, let source = detect(url.absoluteString) { return source }
            }
        }
        if let range = text.range(of: #"\b[0-9a-fA-F]{40}\b"#, options: .regularExpression) {
            return detect(String(text[range]))
        }
        return nil
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
