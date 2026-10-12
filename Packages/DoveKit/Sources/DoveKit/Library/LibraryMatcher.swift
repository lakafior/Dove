import Foundation

/// Finds the metadata (poster, real title) for a guessed library title through the search addon,
/// and remembers the answer on disk so the library does not search on every launch.
public actor MatchStore {
    public enum Entry: Codable, Sendable, Equatable {
        case matched(MediaSummary)
        /// Searched, nothing fitting. Retried after `retryAfter`.
        case unmatched(Date)
        /// Chosen by the user; never replaced automatically.
        case manual(MediaSummary)

        public var media: MediaSummary? {
            switch self {
            case .matched(let media), .manual(let media): media
            case .unmatched: nil
            }
        }
    }

    public static let retryAfter: TimeInterval = 7 * 24 * 3600

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

    /// Whether this key should be looked up now.
    public func needsLookup(_ key: String, now: Date = Date()) -> Bool {
        switch entries[key] {
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

    /// Looks up every key the store has no fresh answer for, a few at a time, and records the results.
    /// `search` is the search addon (`AddonSet.search(_:type:)`). Returns how many keys were looked up.
    @discardableResult
    public static func matchMissing(
        _ guesses: [String: MediaGuess],
        store: MatchStore,
        concurrency: Int = 4,
        search: @escaping @Sendable (String, MediaType) async throws -> [MediaSummary],
        onMatch: @escaping @Sendable (String, MediaSummary) async -> Void = { _, _ in }
    ) async -> Int {
        var pending: [(String, MediaGuess)] = []
        for (key, guess) in guesses where await store.needsLookup(key) {
            pending.append((key, guess))
        }
        await withTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()
            func next() -> Bool {
                guard let (key, guess) = iterator.next() else { return false }
                group.addTask {
                    // A failed search (offline, addon down) records nothing, so it is retried next time.
                    guard let results = try? await search(guess.title, guess.type) else { return }
                    if let media = best(results, for: guess) {
                        await store.set(.matched(media), for: key)
                        await onMatch(key, media)
                    } else {
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
