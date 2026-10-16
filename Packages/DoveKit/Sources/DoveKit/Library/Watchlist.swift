import Foundation

/// Movies and series saved for later. Synced through the Keychain like `SyncedPreferences` (`CredentialKey.watchlist`).
/// Nothing on it is ever added to a service by itself: it only tells what is new, out, or already in the library.
public struct Watchlist: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Hashable, Identifiable {
        public var media: MediaSummary
        /// Every ID this title was seen under: a TMDB search gives `tmdb:…`, its detail the IMDb `tt…`.
        public var ids: Set<String>
        public var addedAt: Date

        public var id: String { media.id }

        public init(media: MediaSummary, otherIDs: [String] = [], addedAt: Date = .now) {
            self.media = media
            ids = Set([media.id] + otherIDs)
            self.addedAt = addedAt
        }
    }

    /// Newest first.
    public private(set) var entries: [Entry] = []

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public func entry(for media: MediaSummary) -> Entry? {
        entries.first { $0.ids.contains(media.id) }
    }

    public func contains(_ media: MediaSummary) -> Bool { entry(for: media) != nil }

    /// Adds a title (or learns another ID of one already on the list).
    public mutating func add(_ media: MediaSummary, otherIDs: [String] = [], now: Date = .now) {
        if let index = entries.firstIndex(where: { !$0.ids.isDisjoint(with: [media.id] + otherIDs) }) {
            entries[index].ids.formUnion([media.id] + otherIDs)
            return
        }
        entries.insert(Entry(media: media, otherIDs: otherIDs, addedAt: now), at: 0)
    }

    public mutating func remove(_ media: MediaSummary) {
        entries.removeAll { $0.ids.contains(media.id) }
    }

    public mutating func remove(ids: Set<String>) {
        entries.removeAll { ids.contains($0.id) }
    }

    /// The library title holding this entry: same ID, else the same normalised name and year.
    public static func title(for entry: Entry, in titles: [LibraryTitle]) -> LibraryTitle? {
        if let match = titles.first(where: { $0.media.map { entry.ids.contains($0.id) } ?? false }) { return match }
        let name = MediaGuess.normalize(entry.media.name)
        let year = entry.media.releaseInfo?.prefix(4)
        return titles.first { title in
            title.type == entry.media.type && MediaGuess.normalize(title.name) == name
                && (year == nil || title.year?.prefix(4) == year)
        }
    }

    public static func load(from keychain: KeychainStore) -> Watchlist {
        guard let json = try? keychain.get(.watchlist),
              let list = try? JSONDecoder().decode(Watchlist.self, from: Data(json.utf8)) else { return Watchlist() }
        return list
    }

    public func save(to keychain: KeychainStore) throws {
        let data = try JSONEncoder().encode(self)
        try keychain.set(entries.isEmpty ? nil : String(decoding: data, as: UTF8.self), for: .watchlist)
    }
}

/// A movie's release dates from TMDB (`release_dates`), the US first, else the earliest anywhere.
public struct MovieRelease: Codable, Sendable, Hashable {
    public var theatrical: Date?
    /// Streaming or purchase: when a movie usually shows up as a web release.
    public var digital: Date?
    public var physical: Date?
    public var fetchedAt: Date

    public init(theatrical: Date? = nil, digital: Date? = nil, physical: Date? = nil, fetchedAt: Date = .now) {
        self.theatrical = theatrical
        self.digital = digital
        self.physical = physical
        self.fetchedAt = fetchedAt
    }
}

/// What the watchlist says about an entry right now.
public enum WatchlistStatus: Sendable, Hashable {
    /// Already in the library; a series may still have new or missing episodes there.
    case inLibrary(episodes: String?)
    /// Series: episodes aired since it was added (newest last).
    case newEpisodes([Episode])
    /// Series: the next episode to air.
    case nextEpisode(Episode)
    /// Movie: out digitally (or on disc), so releases exist.
    case out(since: Date)
    case digitalOn(Date)
    case inTheaters(since: Date)
    case theatricalOn(Date)

    /// "In library", "2 new · S02E03", "S03E04 · 21 Oct", "Out now", "Digital 12 Nov", "In theaters".
    public func label(now: Date = .now) -> String {
        switch self {
        case .inLibrary(let episodes): episodes.map { "In library · \($0)" } ?? "In library"
        case .newEpisodes(let list): list.count == 1 ? "New \(list[0].code)" : "\(list.count) new · \(list.last!.code)"
        case .nextEpisode(let episode): "\(episode.code) · \(Self.day(episode.released, now: now))"
        case .out: "Out now"
        case .digitalOn(let date): "Digital \(Self.day(date, now: now))"
        case .inTheaters: "In theaters"
        case .theatricalOn(let date): "Theaters \(Self.day(date, now: now))"
        }
    }

    /// Worth a notification when it first appears: new episodes (by the newest), a movie that is out.
    public var announcement: String? {
        switch self {
        case .newEpisodes(let list): list.last.map { "new:\($0.season)x\($0.number)" }
        case .out: "out"
        default: nil
        }
    }

    /// "Today", "Tomorrow", "21 Oct", "21 Oct 2027".
    static func day(_ date: Date?, now: Date) -> String {
        guard let date else { return "soon" }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear ? .dateTime.day().month(.abbreviated) : .dateTime.day().month(.abbreviated).year())
    }

    /// - Parameters:
    ///   - inLibrary: the entry's library title, if the library holds it (`Watchlist.title(for:in:)`).
    ///   - review: that title's library review, for series.
    public static func of(
        _ entry: Watchlist.Entry,
        inLibrary: Bool,
        review: TitleReview? = nil,
        schedule: EpisodeSchedule? = nil,
        release: MovieRelease? = nil,
        now: Date = .now
    ) -> WatchlistStatus? {
        if inLibrary { return .inLibrary(episodes: review?.episodeSummary) }
        switch entry.media.type {
        case .series:
            let episodes = (schedule?.episodes ?? [])
                .filter { $0.season > 0 }
                .sorted { ($0.season, $0.number) < ($1.season, $1.number) }
                .map { Episode(id: $0.id, season: $0.season, number: $0.number, title: $0.title, released: $0.released) }
            let new = episodes.filter { ($0.released.map { $0 > entry.addedAt && $0 <= now }) ?? false }
            if !new.isEmpty { return .newEpisodes(new) }
            if let next = episodes.first(where: { ($0.released ?? .distantPast) > now }) { return .nextEpisode(next) }
            return nil
        case .movie:
            guard let release else { return nil }
            let home = [release.digital, release.physical].compactMap { $0 }.min()
            if let home, home <= now { return .out(since: home) }
            if let digital = release.digital { return .digitalOn(digital) }
            if let theatrical = release.theatrical {
                return theatrical <= now ? .inTheaters(since: theatrical) : .theatricalOn(theatrical)
            }
            return nil
        }
    }
}

extension Episode {
    /// "S02E03".
    public var code: String { SeriesScope.episodes(season: season, [number]).label }
}
