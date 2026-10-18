import Foundation

/// A file format a book or audiobook release names: "[EPUB]", ".m4b", "MP3 64kbps".
public enum BookFileFormat: String, Sendable, Hashable, CaseIterable, Comparable {
    case epub, pdf, kindle, fb2, djvu, comic, m4b, mp3, aac, flac

    public var displayName: String {
        switch self {
        case .epub: "EPUB"
        case .pdf: "PDF"
        case .kindle: "MOBI/AZW3"
        case .fb2: "FB2"
        case .djvu: "DjVu"
        case .comic: "CBZ/CBR"
        case .m4b: "M4B"
        case .mp3: "MP3"
        case .aac: "AAC"
        case .flac: "FLAC"
        }
    }

    public var isAudio: Bool {
        switch self {
        case .m4b, .mp3, .aac, .flac: true
        default: false
        }
    }

    /// Name tokens that stand for the format.
    static let tokens: [String: BookFileFormat] = [
        "epub": .epub, "pdf": .pdf, "mobi": .kindle, "azw": .kindle, "azw3": .kindle, "kfx": .kindle,
        "fb2": .fb2, "djvu": .djvu, "cbz": .comic, "cbr": .comic,
        "m4b": .m4b, "mp3": .mp3, "m4a": .aac, "aac": .aac, "flac": .flac,
    ]

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// What a book or audiobook result from an indexer holds, read without its files (Newznab and Torznab list
/// none, and fetching every NZB or .torrent would spend the indexers' daily hits).
///
/// Indexers mix the two: Jackett and Prowlarr often tag an audiobook both Audio › Audiobook (3030) and Books
/// (7000), and many Newznab indexers file audiobooks under Books. Evidence, strongest first:
/// 1. the Audiobook category (3030);
/// 2. the name: an audio format (`M4B`, `MP3`), audiobook words (`Unabridged`, `Narrated by`, `64kbps`), or an
///    ebook format (`EPUB`, `PDF`, `CBR`);
/// 3. the size, only for Books results the name says nothing about: ebooks are a few MB, audiobooks hundreds.
///    Comics (7030) and magazines (7010) come in big packs, and collections say so, so neither counts by size.
public struct BookRelease: Sendable, Hashable {
    /// Formats the name mentions, in `BookFileFormat` order.
    public var formats: [BookFileFormat]
    /// `.books`, `.audiobooks`, or nil when nothing says which.
    public var kind: ContentKind?

    /// Above this, a Books result with a silent name is taken for an audiobook.
    static let audiobookSize: Int64 = 300_000_000

    public init(name: String, category: Int?, size: Int64?) {
        let text = name.lowercased()
        let words = Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        formats = Set(words.compactMap { BookFileFormat.tokens[$0] }).sorted()

        let audio = formats.contains(where: \.isAudio)
            || ContentClassifier.isAudiobook(name: name)
            || text.range(of: #"\d+ ?kbps"#, options: .regularExpression) != nil
        let ebook = formats.contains { !$0.isAudio }
            || text.range(of: #"\be-?books?\b"#, options: .regularExpression) != nil

        if category == 3030 || audio && !ebook {
            kind = .audiobooks
        } else if ebook || category.map({ [7010, 7030].contains($0) }) == true {
            kind = .books
        } else if let category, category / 1000 == 7 {
            let pack = text.range(of: #"\b(collection|pack|bundle|complete series|omnibus)\b"#, options: .regularExpression) != nil
            kind = !pack && (size ?? 0) > Self.audiobookSize ? .audiobooks : .books
        } else {
            kind = nil
        }
    }

    public init(_ group: StreamGroup) {
        self.init(name: group.title, category: group.category, size: group.size)
    }
}

extension StreamGroup {
    /// The kind for rows and adds: the indexer's category, told apart from the name and size for books and
    /// audiobooks (`BookRelease`).
    public var contentKind: ContentKind {
        let byCategory = category.map(ContentKind.init(newznabCategory:)) ?? .other
        guard byCategory == .books || byCategory == .audiobooks else { return byCategory }
        return BookRelease(self).kind ?? byCategory
    }

    /// Books and Audiobooks searches: what belongs to the category searched, and what the indexers filed there
    /// but is the other one (shown on request). Other categories pass untouched.
    public static func splitByBookKind(_ groups: [StreamGroup], for category: NewznabCategory)
        -> (matching: [StreamGroup], other: [StreamGroup])
    {
        let wanted: ContentKind
        switch category {
        case .books: wanted = .books
        case .audiobooks: wanted = .audiobooks
        default: return (groups, [])
        }
        var matching: [StreamGroup] = [], other: [StreamGroup] = []
        for group in groups {
            let kind = BookRelease(group).kind
            if kind == nil || kind == wanted { matching.append(group) } else { other.append(group) }
        }
        return (matching, other)
    }
}
