import Foundation

/// Metadata matches for guessed library titles (movies and series).
public typealias MatchStore = MetadataStore<MediaSummary>

/// Remembers the metadata (poster, real title) found for guessed library titles on disk, so the library does
/// not search on every launch. One store per kind of metadata: titles (`MatchStore`), books (`BookSummary`).
public actor MetadataStore<Media: Codable & Sendable & Equatable> {
    public enum Entry: Codable, Sendable, Equatable {
        case matched(Media)
        /// Searched, nothing fitting. Retried after `retryAfter`.
        case unmatched(Date)
        /// Chosen by the user; never replaced automatically.
        case manual(Media)

        public var media: Media? {
            switch self {
            case .matched(let media), .manual(let media): media
            case .unmatched: nil
            }
        }
    }

    public static var retryAfter: TimeInterval { 7 * 24 * 3600 }

    private let fileURL: URL?
    private var entries: [String: Entry]

    /// `fileURL` nil keeps everything in memory (tests).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    public func entry(for key: String) -> Entry? { entries[key] }

    public func all() -> [String: Entry] { entries }

    public func set(_ entry: Entry, for key: String) {
        entries[key] = entry
        save()
    }

    public func remove(_ key: String) {
        entries[key] = nil
        save()
    }

    /// Whether this key should be looked up now. `everything` (re-match all) takes every key but the user's choices.
    public func needsLookup(_ key: String, everything: Bool = false, now: Date = Date()) -> Bool {
        if everything, case .manual = entries[key] { return false }
        if everything { return true }
        return switch entries[key] {
        case nil: true
        case .unmatched(let date): now.timeIntervalSince(date) > Self.retryAfter
        case .matched, .manual: false
        }
    }

    private func save() {
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: fileURL, options: .atomic) }
    }
}

public enum LibraryMatcher {
    /// Picks the best search result for a guess: same normalised title and year first, then same title,
    /// then a year match among close titles, then the first result. Nil when the search found nothing.
    public static func best(_ results: [MediaSummary], for guess: MediaGuess) -> MediaSummary? {
        let wanted = MediaGuess.normalize(guess.title)
        let candidates = results.filter { $0.type == guess.type }
        guard !candidates.isEmpty else { return nil }
        func year(_ media: MediaSummary) -> Int? {
            media.releaseInfo.flatMap { Int($0.prefix(4)) }
        }
        let sameTitle = candidates.filter { MediaGuess.normalize($0.name) == wanted }
        if let guessYear = guess.year {
            if let exact = sameTitle.first(where: { year($0) == guessYear }) { return exact }
            if let close = candidates.first(where: {
                year($0) == guessYear && (MediaGuess.normalize($0.name).contains(wanted) || wanted.contains(MediaGuess.normalize($0.name)))
            }) { return close }
        }
        return sameTitle.first ?? candidates.first
    }

    /// Items Dove added from a title's screen are that title: their hint's media becomes the match for their
    /// guess, without a search. The user's own choices stay; a different automatic match is replaced.
    /// Returns the matches it set, by guess key.
    @discardableResult
    public static func applyHints(_ items: [ShelfItem], store: MatchStore) async -> [String: MediaSummary] {
        var applied: [String: MediaSummary] = [:]
        for item in items where item.kind == .video {
            guard let media = item.hint?.media, media.type == item.guess.type, applied[item.guess.key] == nil else { continue }
            let key = item.guess.key
            switch await store.entry(for: key) {
            case .manual: continue
            case .matched(let current) where current.id == media.id: continue
            default:
                await store.set(.matched(media), for: key)
                applied[key] = media
            }
        }
        return applied
    }

    /// Books added or downloaded from a book's screen: the book they were found for, without a search. Like
    /// `applyHints`, the user's own choice stays.
    public static func applyBookHints(_ items: [ShelfItem], store: MetadataStore<BookSummary>) async -> [String: BookSummary] {
        var applied: [String: BookSummary] = [:]
        for item in items {
            guard let book = item.hint?.book, let key = item.bookGuess?.key, applied[key] == nil else { continue }
            switch await store.entry(for: key) {
            case .manual: continue
            case .matched(let current) where current.id == book.id: continue
            default:
                await store.set(.matched(book), for: key)
                applied[key] = book
            }
        }
        return applied
    }

    /// Looks up every key the store has no fresh answer for, a few at a time, and records the results.
    /// `search` is TMDB or the search addon (`AddonSet.search(_:type:)`). Returns how many keys were looked up.
    /// `everything` re-matches automatic matches too (e.g. after adding a TMDB key); the user's own choices stay,
    /// and a match is only replaced by a new one, never dropped because the new search found nothing.
    @discardableResult
    public static func matchMissing(
        _ guesses: [String: MediaGuess],
        store: MatchStore,
        everything: Bool = false,
        concurrency: Int = 4,
        search: @escaping @Sendable (String, MediaType) async throws -> [MediaSummary],
        onMatch: @escaping @Sendable (String, MediaSummary) async -> Void = { _, _ in }
    ) async -> Int {
        await matchMissing(guesses, store: store, everything: everything, concurrency: concurrency, lookup: { guess in
            best(try await search(guess.title, guess.type), for: guess)
        }, onMatch: onMatch)
    }

    /// The same for any kind of guess and metadata: `lookup` answers one guess (nil: nothing fitting; a throw:
    /// try again next time).
    @discardableResult
    public static func matchMissing<Guess: Sendable, Media: Codable & Sendable & Equatable>(
        _ guesses: [String: Guess],
        store: MetadataStore<Media>,
        everything: Bool = false,
        concurrency: Int = 4,
        lookup: @escaping @Sendable (Guess) async throws -> Media?,
        onMatch: @escaping @Sendable (String, Media) async -> Void = { _, _ in }
    ) async -> Int {
        var pending: [(String, Guess)] = []
        for (key, guess) in guesses where await store.needsLookup(key, everything: everything) {
            pending.append((key, guess))
        }
        await withTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()
            func next() -> Bool {
                guard let (key, guess) = iterator.next() else { return false }
                group.addTask {
                    // A failed search (offline, addon down) records nothing, so it is retried next time.
                    let found: Media?
                    do { found = try await lookup(guess) } catch { return }
                    if let media = found {
                        await store.set(.matched(media), for: key)
                        await onMatch(key, media)
                    } else if await store.entry(for: key)?.media == nil {
                        await store.set(.unmatched(Date()), for: key)
                    }
                }
                return true
            }
            for _ in 0..<concurrency where next() {}
            while await group.next() != nil {
                _ = next()
            }
        }
        return pending.count
    }
}
