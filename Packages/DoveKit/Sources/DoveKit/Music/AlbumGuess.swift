import Foundation

/// Artist, album and year read from a music release name:
/// "Green Day - Dookie (30th Anniversary Deluxe Edition)  (2023) [24Bit-192kHz] FLAC [PMEDIA] ⭐️",
/// "Daft_Punk-Discovery-CD-FLAC-2001-PERFECT", "Radiohead - OK Computer (1997) [MP3 320]".
public struct AlbumGuess: Sendable, Hashable, Codable {
    public var title: String
    public var artist: String?
    /// The year the name gives; a reissue's, not always the album's first release.
    public var year: Int?

    /// Groups releases of one album: `music|greenday|dookie`.
    public var key: String {
        "music|\(MediaGuess.normalize(artist ?? ""))|\(MediaGuess.normalize(title))"
    }

    /// What a metadata search gets.
    public var query: String {
        [artist, title].compactMap { $0 }.joined(separator: " ")
    }

    public init(title: String, artist: String? = nil, year: Int? = nil) {
        self.title = title
        self.artist = artist
        self.year = year
    }

    private static let extensions: Set<String> = [
        "flac", "mp3", "m4a", "aac", "ogg", "opus", "wav", "aiff", "alac", "ape", "wv", "dsf", "zip", "rar", "7z",
    ]

    /// Words that end the album's title in scene names and trail in tidy ones: formats, sources, qualities, groups.
    private static let stopWords: Set<String> = [
        "flac", "mp3", "aac", "alac", "ogg", "opus", "wav", "aiff", "dsd", "dsf", "ape", "wv", "m4a",
        "web", "webflac", "cd", "cdda", "cdm", "cdr", "cds", "vinyl", "lp", "ep", "sacd", "hdtracks", "qobuz", "tidal",
        "deezer", "itunes", "bandcamp", "retail", "promo", "advance", "bootleg", "remastered", "remaster", "reissue",
        "deluxe", "expanded", "limited", "edition", "anniversary", "bonus", "explicit", "clean",
        "320", "320kbps", "256", "256kbps", "192", "192kbps", "v0", "v2", "vbr", "cbr", "kbps", "lossless", "hires",
        "hi", "res", "24bit", "16bit", "24", "16", "bit", "44", "48", "88", "96", "176", "192khz", "96khz", "44khz",
        "48khz", "khz", "mqa", "atmos", "multichannel", "discography", "pmedia",
    ]

    /// Parentheses and brackets that hold no part of the title: years, editions, formats.
    private static let noise = #"(?i)\b(19|20)\d{2}\b|edition|remaster|deluxe|anniversary|bonus|expanded|reissue|flac|mp3|kbps|khz|bit|web|cd|vinyl|explicit|hi-?res|lossless|mqa|atmos|pmedia"#

    public init(releaseName name: String) {
        var base = name.trimmingCharacters(in: .whitespaces)
        if Self.extensions.contains((base as NSString).pathExtension.lowercased()) {
            base = (base as NSString).deletingPathExtension
        }
        // Emoji and other symbols (⭐️ in tracker names).
        base = String(base.unicodeScalars.filter { !$0.properties.isEmojiPresentation && $0.properties.generalCategory != .otherSymbol }.map(Character.init))
        year = Self.lastYear(in: base)

        // A tidy name: "Artist - Album (…) [...] FLAC". Scene names have no spaced dash.
        if base.contains(" - ") || base.contains(" – ") {
            let parts = base.replacingOccurrences(of: " – ", with: " - ").components(separatedBy: " - ")
            artist = Self.clean(parts[0]).nilIfEmpty
            title = Self.titleWords(Self.clean(parts.dropFirst().joined(separator: " - ")))
        } else {
            // "Daft_Punk-Discovery-CD-FLAC-2001-PERFECT", "Artist.Name-Album.Title-WEB-2023-GRP".
            let spaced = base.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
            let parts = spaced.components(separatedBy: "-").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if parts.count >= 2 {
                artist = Self.clean(parts[0]).nilIfEmpty
                var words: [String] = []
                for part in parts.dropFirst() {
                    let lower = part.lowercased()
                    if Self.stopWords.contains(lower) || Int(lower).map({ (1900...2099).contains($0) }) == true { break }
                    words.append(part)
                }
                title = Self.titleWords(Self.clean(words.joined(separator: " - ")))
            } else {
                artist = nil
                title = Self.titleWords(Self.clean(spaced))
            }
        }
        if title.isEmpty { title = Self.clean(base) }
    }

    /// Without bracketed tags (years, editions, formats) and spare spaces; other parentheses stay, as in
    /// "(What's the Story) Morning Glory?".
    private static func clean(_ text: String) -> String {
        var text = text.replacingOccurrences(of: #"\[[^\]]*\]|\{[^\}]*\}"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\(([^\)]*)\)"#, with: " ", options: .regularExpression, range: nil, onlyMatching: noise)
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// The title without trailing format words ("Dookie FLAC" → "Dookie").
    private static func titleWords(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        while let last = words.last, stopWords.contains(last.lowercased().filter { $0.isLetter || $0.isNumber }) {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    private static func lastYear(in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![0-9])(19[5-9][0-9]|20[0-9]{2})(?![0-9])"#) else { return nil }
        let last = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last
        return last.flatMap { Range($0.range, in: text) }.flatMap { Int(text[$0]) }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

    /// Replaces each match of `pattern` whose text also matches `onlyMatching`.
    func replacingOccurrences(of pattern: String, with replacement: String, options: String.CompareOptions, range: Range<Index>?, onlyMatching filter: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        var result = self
        for match in regex.matches(in: self, range: NSRange(startIndex..., in: self)).reversed() {
            guard let found = Range(match.range, in: self), self[found].range(of: filter, options: .regularExpression) != nil else { continue }
            result.replaceSubrange(Range(match.range, in: result)!, with: replacement)
        }
        return result
    }
}

extension AlbumMatcher {
    /// The search result that is the guessed album, or none (a missing cover beats a wrong one): the same title
    /// (or one containing it, from 4 letters), and the artist when the name gives one. Studio albums and official
    /// releases come first in `MusicMetadata.search`'s order, so the first fit wins.
    public static func best(_ results: [AlbumSummary], for guess: AlbumGuess) -> AlbumSummary? {
        let wanted = MediaGuess.normalize(guess.title)
        guard wanted.count >= 2 else { return nil }
        let artist = guess.artist.map(MediaGuess.normalize).flatMap { $0.isEmpty ? nil : $0 }
        func fits(_ album: AlbumSummary, exact: Bool) -> Bool {
            let title = MediaGuess.normalize(album.searchTitle)
            let titleFits = exact ? title == wanted : min(title.count, wanted.count) >= 4 && (title.contains(wanted) || wanted.contains(title))
            guard titleFits else { return false }
            guard let artist else { return true }
            let artists = album.artists.map(MediaGuess.normalize)
            return artists.contains { $0 == artist || ($0.count >= 3 && (artist.contains($0) || $0.contains(artist))) }
        }
        return results.first { fits($0, exact: true) } ?? results.first { fits($0, exact: false) }
    }
}

extension MusicMetadata {
    /// The album a library item is, from its guessed artist and title; nil when nothing fits.
    public func match(_ guess: AlbumGuess) async throws -> AlbumSummary? {
        AlbumMatcher.best(try await search(guess.query), for: guess)
    }
}

extension ShelfItem {
    /// Artist and album from the name, for music items.
    public var albumGuess: AlbumGuess? {
        kind == .music ? AlbumGuess(releaseName: name) : nil
    }
}
