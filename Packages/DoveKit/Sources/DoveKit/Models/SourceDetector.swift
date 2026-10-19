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
        // A movie's page (IMDb, Apple TV, Letterboxd…) is a title to open, not a file to unlock.
        if TitleLink(url: url) != nil { return nil }
        return .hosterURL(url)
    }

    /// Every source in a text, in reading order, each once: magnets, links Dove can use, bare info hashes (outside
    /// magnets and links). A list of hoster links pasted at once becomes one add.
    public static func sources(in text: String) -> [Source] {
        let whole = NSRange(text.startIndex..., in: text)
        var found: [(location: Int, source: Source)] = []
        var taken: [NSRange] = []

        if let magnets = try? NSRegularExpression(pattern: #"magnet:\?[^\s"'<>]+"#, options: .caseInsensitive) {
            for match in magnets.matches(in: text, range: whole) {
                guard let range = Range(match.range, in: text) else { continue }
                found.append((match.range.location, .magnet(String(text[range]))))
                taken.append(match.range)
            }
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: whole) where !taken.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                guard let url = match.url, let source = detect(url.absoluteString) else { continue }
                found.append((match.range.location, source))
                taken.append(match.range)
            }
        }
        if let hashes = try? NSRegularExpression(pattern: #"\b[0-9a-fA-F]{40}\b"#) {
            for match in hashes.matches(in: text, range: whole) where !taken.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                guard let range = Range(match.range, in: text), let source = detect(String(text[range])) else { continue }
                found.append((match.range.location, source))
            }
        }

        var seen = Set<String>()
        return found
            .sorted { $0.location < $1.location }
            .map(\.source)
            .filter { seen.insert($0.id).inserted }
    }

    /// A URL handed to the app or the share extension: a `magnet:` link, a `.torrent`/`.nzb` file
    /// (read under security-scoped access, since Files opens them in place), or a web link.
    public static func source(opening url: URL) -> Source? {
        if url.isFileURL { return fileSource(at: url) }
        if url.scheme?.lowercased() == "magnet" { return .magnet(url.absoluteString) }
        return detect(url.absoluteString)
    }

    static func fileSource(at url: URL) -> Source? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let kind = url.pathExtension.lowercased()
        guard kind == "torrent" || kind == "nzb", let data = try? Data(contentsOf: url) else { return nil }
        return kind == "torrent"
            ? .torrentFile(data: data, filename: url.lastPathComponent)
            : .nzbFile(data: data, filename: url.lastPathComponent)
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
