import Foundation

/// Picks the search result that is the guessed book, or none: a missing cover is better than a wrong one.
public enum BookMatcher {
    /// Best result for a guess, in the service's relevance order on ties. A result needs the same title, or a
    /// title that contains (or is contained in) the guess's and an author in common. Author and title may be
    /// swapped in the release name; without an author, the guess's title may hold the author's name too.
    public static func best(_ results: [BookSummary], for guess: BookGuess) -> BookSummary? {
        var best: (book: BookSummary, score: Int)?
        for book in results {
            guard let score = score(book, for: guess), score > (best?.score ?? 0) else { continue }
            best = (book, score)
        }
        return best?.book
    }

    static func score(_ book: BookSummary, for guess: BookGuess) -> Int? {
        let full = MediaGuess.normalize(withoutEdition(book.title))
        // "Mistborn: The Final Empire" also answers to "Mistborn".
        let main = MediaGuess.normalize(withoutEdition(book.title).components(separatedBy: ":")[0])
        let authors = book.authors.map(MediaGuess.normalize).filter { !$0.isEmpty }
        let orientations: [(title: String, author: String?)] = guess.author.map {
            [(guess.title, $0), ($0, guess.title)]
        } ?? [(guess.title, nil)]

        var best: Int?
        for (title, author) in orientations {
            let wanted = MediaGuess.normalize(title)
            guard wanted.count >= 2, !full.isEmpty else { continue }
            let titleScore: Int
            if wanted == full || wanted == main {
                titleScore = 3
            } else if min(wanted.count, main.count) >= 4, full.contains(wanted) || wanted.contains(main) {
                titleScore = 1
            } else {
                continue
            }
            let authorScore: Int
            if let author {
                authorScore = authorMatch(MediaGuess.normalize(author), authors)
            } else {
                // "Andy Weir Project Hail Mary" as the whole title.
                authorScore = authors.contains { $0.count >= 4 && wanted.contains($0) } ? 2 : 0
            }
            guard titleScore == 3 || authorScore > 0 else { continue }
            var score = titleScore * 2 + authorScore
            if let year = guess.year, year == book.year { score += 1 }
            if book.cover != nil { score += 1 }
            best = max(best ?? 0, score)
        }
        return best
    }

    /// 2: same author; 1: a surname in common ("Sanderson" and "Brandon Sanderson"); 0: none.
    private static func authorMatch(_ wanted: String, _ authors: [String]) -> Int {
        guard !wanted.isEmpty else { return 0 }
        if authors.contains(wanted) { return 2 }
        return authors.contains { $0.count >= 4 && (wanted.contains($0) || $0.contains(wanted)) } ? 1 : 0
    }

    /// "Project Hail Mary (Unabridged)" → "Project Hail Mary".
    static func withoutEdition(_ title: String) -> String {
        title.replacingOccurrences(
            of: #"\s*[\(\[](un)?abridged( edition)?[\)\]]\s*$"#, with: "", options: [.regularExpression, .caseInsensitive]
        )
    }
}
