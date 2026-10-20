import Foundation

/// The books the library already holds, to mark search results ("In Calibre") before anything is downloaded twice.
/// Strict on purpose: a result counts only with the same title (or the same title before a subtitle), the same
/// format, and an author in common when both name one. A missed mark costs a look; a wrong one hides a book.
public struct HeldBooks: Sendable {
    private var byTitle: [String: [BookTitle]] = [:]

    public init(_ titles: [BookTitle]) {
        for title in titles {
            for key in Self.titleKeys(title.name) { byTitle[key, default: []].append(title) }
        }
    }

    public var isEmpty: Bool { byTitle.isEmpty }

    /// The library's book for a search result, or nil.
    public func held(_ book: BookSummary, format: BookFormat) -> BookTitle? {
        let authors = Self.authorWords(book.authors)
        var seen: Set<String> = []
        for key in Self.titleKeys(book.title) {
            for title in byTitle[key] ?? [] where seen.insert(title.id).inserted && title.format == format {
                if title.book?.id == book.id { return title }
                let theirs = Self.authorWords(title.book?.authors ?? title.author.map { [$0] } ?? [])
                if authors.isEmpty || theirs.isEmpty || !authors.isDisjoint(with: theirs) { return title }
            }
        }
        return nil
    }

    /// The whole title and, for "Mistborn: The Final Empire", the part before the subtitle; editions dropped.
    static func titleKeys(_ title: String) -> [String] {
        let plain = BookMatcher.withoutEdition(title)
        let keys = [plain, plain.components(separatedBy: ":")[0]]
            .map(MediaGuess.normalize)
            .filter { $0.count >= 2 }
        return Array(Set(keys))
    }

    /// Name words of three letters or more: "Feynman Richard P." and "Richard P. Feynman" share "feynman".
    static func authorWords(_ authors: [String]) -> Set<String> {
        Set(authors.flatMap { author in
            author.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .split { !$0.isLetter }
                .map(String.init)
                .filter { $0.count >= 3 }
        })
    }
}
