import Foundation

/// Read or listened to: picks the metadata source and the cover's shape (books 2:3, audiobooks square).
public enum BookFormat: String, Sendable, Codable, Hashable {
    case ebook, audiobook

    public init?(kind: ContentKind) {
        switch kind {
        case .books: self = .ebook
        case .audiobooks: self = .audiobook
        default: return nil
        }
    }
}

/// Author and title read from a book or audiobook release name:
/// "Andy Weir - Project Hail Mary (2021) [epub]", "Brandon.Sanderson.-.Mistborn.RETAIL.EPUB",
/// "Project Hail Mary by Andy Weir (Unabridged) [Ray Porter]".
public struct BookGuess: Sendable, Hashable, Codable {
    public var title: String
    public var author: String?
    public var year: Int?
    public var format: BookFormat

    /// Groups releases of one book in one format: `audiobook|andyweir|projecthailmary`.
    public var key: String {
        "\(format.rawValue)|\(MediaGuess.normalize(author ?? ""))|\(MediaGuess.normalize(title))"
    }

    /// What a metadata search gets: author and title together, which also works when they are swapped.
    public var query: String {
        [author, title].compactMap { $0 }.joined(separator: " ")
    }

    public init(title: String, author: String? = nil, year: Int? = nil, format: BookFormat) {
        self.title = title
        self.author = author
        self.year = year
        self.format = format
    }

    /// File extensions dropped from the name (books, audio, archives).
    private static let extensions: Set<String> = [
        "epub", "pdf", "mobi", "azw", "azw3", "djvu", "fb2", "cbz", "cbr", "m4b", "m4a", "mp3", "aac", "flac", "zip", "rar", "7z",
    ]

    /// Words that end the title: formats, editions, bitrates.
    private static let stopWords: Set<String> = [
        "epub", "pdf", "mobi", "azw", "azw3", "djvu", "fb2", "retail", "ebook", "e-book", "ebooks",
        "audiobook", "audiobooks", "unabridged", "abridged", "mp3", "m4b", "aac", "flac", "vbr", "kbps",
    ]

    public init(releaseName name: String, format: BookFormat) {
        self.format = format
        var base = name.trimmingCharacters(in: .whitespaces)
        if Self.extensions.contains((base as NSString).pathExtension.lowercased()) {
            base = (base as NSString).deletingPathExtension
        }
        // A year in brackets is the only one that is surely not part of the title ("1984").
        let bracketYear = base.range(of: #"[\(\[](1[5-9]|20)\d{2}[\)\]]"#, options: .regularExpression)
            .flatMap { Int(base[$0].dropFirst().dropLast()) }
        base = base.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|\{[^}]*\}"#, with: " ", options: .regularExpression)
        base = base.contains(" ")
            ? base.replacingOccurrences(of: "_", with: " ")
            : base.replacingOccurrences(of: #"[._]"#, with: " ", options: .regularExpression)
        base = base.replacingOccurrences(of: #"\s+-\s+"#, with: " - ", options: .regularExpression)

        // Cut at "read by", "narrated by" and the first format word.
        if let range = base.range(of: #"\s(read|narrated) by\s"#, options: [.regularExpression, .caseInsensitive]) {
            base = String(base[..<range.lowerBound])
        }
        var kept: [Substring] = []
        for token in base.split(separator: " ") {
            let word = token.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if Self.stopWords.contains(word) || word.range(of: #"^\d+kbps$"#, options: .regularExpression) != nil { break }
            kept.append(token)
        }
        base = kept.joined(separator: " ")

        var title = base
        var author: String?
        let parts = base.components(separatedBy: " - ").map(Self.trim).filter { !$0.isEmpty }
        if parts.count >= 2 {
            author = parts[0]
            title = parts.dropFirst().joined(separator: " - ")
        } else if let range = base.range(of: " by ", options: [.caseInsensitive, .backwards]) {
            title = String(base[..<range.lowerBound])
            author = String(base[range.upperBound...])
        }

        // "Project Hail Mary 2021": a trailing year after at least one word of title.
        var year = bracketYear
        var words = Self.trim(title).split(separator: " ")
        if words.count > 1, let last = words.last, last.count == 4, let value = Int(last), (1500...2099).contains(value) {
            year = year ?? value
            words.removeLast()
        }
        let cleanTitle = Self.trim(words.joined(separator: " "))
        self.title = cleanTitle.isEmpty ? Self.trim(name) : cleanTitle
        self.author = author.map(Self.trim).flatMap { $0.isEmpty ? nil : $0 }
        self.year = year
    }

    private static func trim(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: " -–:,"))
    }
}

extension ShelfItem {
    /// Author and title for books and audiobooks; nil for every other kind.
    public var bookGuess: BookGuess? {
        BookFormat(kind: kind).map { BookGuess(releaseName: name, format: $0) }
    }
}
