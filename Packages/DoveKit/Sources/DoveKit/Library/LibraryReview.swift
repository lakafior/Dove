import Foundation

/// A series' episode list with air dates, kept between launches so the library review costs one metadata call
/// per series and `maxAge`, not one per launch.
public struct EpisodeSchedule: Codable, Sendable, Hashable {
    public struct Entry: Codable, Sendable, Hashable {
        /// Stream ID (`tt…:1:2`), for the source search.
        public var id: String
        public var season: Int
        public var number: Int
        public var title: String?
        public var released: Date?
    }

    public var fetchedAt: Date
    public var episodes: [Entry]

    public init(detail: MediaDetail, fetchedAt: Date = .now) {
        self.fetchedAt = fetchedAt
        episodes = detail.episodes.map { Entry(id: $0.id, season: $0.season, number: $0.number, title: $0.title, released: $0.released) }
    }

    /// The metadata `SeriesLayout` reads.
    public func detail(for media: MediaSummary) -> MediaDetail {
        MediaDetail(summary: media, episodes: episodes.map {
            Episode(id: $0.id, season: $0.season, number: $0.number, title: $0.title, released: $0.released)
        })
    }
}

/// Episode lists by `MediaSummary.id`, on disk (device-local, not secret).
public actor EpisodeScheduleStore {
    /// Ongoing shows get new air dates; a day-old list is good enough for "new episodes" at launch.
    public static var maxAge: TimeInterval { 12 * 3600 }

    private let fileURL: URL?
    private var schedules: [String: EpisodeSchedule]

    /// `fileURL` nil keeps everything in memory (tests).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: EpisodeSchedule].self, from: data) {
            schedules = decoded
        } else {
            schedules = [:]
        }
    }

    public func all() -> [String: EpisodeSchedule] { schedules }

    public func needsRefresh(_ mediaID: String, now: Date = .now) -> Bool {
        guard let schedule = schedules[mediaID] else { return true }
        return now.timeIntervalSince(schedule.fetchedAt) > Self.maxAge
    }

    public func set(_ schedule: EpisodeSchedule, for mediaID: String) {
        schedules[mediaID] = schedule
        save()
    }

    /// Drops series no longer in the library.
    public func prune(keeping mediaIDs: Set<String>) {
        let before = schedules.count
        schedules = schedules.filter { mediaIDs.contains($0.key) }
        if schedules.count != before { save() }
    }

    private func save() {
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(schedules) { try? data.write(to: fileURL, options: .atomic) }
    }
}

/// What the user set aside in the review: episodes they do not want ("S01–S03 is enough") and quality notes
/// they accept. A dismissed note comes back only when something changes: a newer episode airs, or the
/// library's quality for the title changes.
public struct ReviewDismissals: Codable, Sendable, Equatable {
    /// Title ID → episode keys (`season x number`).
    public var episodes: [String: Set<String>] = [:]
    /// Title ID → the quality label that was accepted.
    public var quality: [String: String] = [:]

    public init() {}

    public static func load(from url: URL) -> ReviewDismissals? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ReviewDismissals.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// Prunes titles that left the library.
    public mutating func keep(only titleIDs: Set<String>) {
        episodes = episodes.filter { titleIDs.contains($0.key) }
        quality = quality.filter { titleIDs.contains($0.key) }
    }
}

/// One title's findings: episodes of a show the user follows that aired since they last added something (`new`),
/// gaps in seasons the
/// library holds part of (`missing`), seasons it holds nothing of (`unstarted`), and releases worth replacing.
public struct TitleReview: Identifiable, Sendable, Hashable {
    public struct WeakSpot: Sendable, Hashable {
        /// Nil for a movie.
        public var season: Int?
        public var quality: ReleaseQuality
    }

    public let titleID: String
    public var new: [Episode] = []
    public var missing: [Episode] = []
    /// Aired episodes of seasons the library holds nothing of: the user may not want them, so they are not
    /// reported (the title screen's seasons already say "Not in your library").
    public var unstarted: [Episode] = []
    /// Movies: the best release held, when it is weak. Series: each season whose worst episode is weak.
    public var weak: [WeakSpot] = []
    /// Air date of the newest `new` episode, to sort titles.
    public var latestAired: Date? { new.compactMap(\.released).max() }

    public var id: String { titleID }
    /// New episodes or gaps: what the home screen lists.
    public var hasEpisodes: Bool { !new.isEmpty || !missing.isEmpty }
    public var isEmpty: Bool { !hasEpisodes && unstarted.isEmpty && weak.isEmpty }

    /// "3 new", "Missing 5", "2 new · missing 4".
    public var episodeSummary: String? {
        var parts: [String] = []
        if !new.isEmpty { parts.append("\(new.count) new") }
        if !missing.isEmpty { parts.append(parts.isEmpty ? "Missing \(missing.count)" : "missing \(missing.count)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "720p", "S2: AV1"; the first weak spot only.
    public var qualitySummary: String? {
        guard let spot = weak.first, let reason = spot.quality.weaknesses.first else { return nil }
        let more = weak.count > 1 ? " +\(weak.count - 1)" : ""
        return (spot.season.map { "S\($0): " } ?? "") + reason + more
    }
}

public enum LibraryReview {
    /// Key for an episode in dismissals and coverage.
    public static func key(season: Int, number: Int) -> String { "\(season)x\(number)" }

    /// - Parameters:
    ///   - schedule: the series' episode list; without it only quality is reviewed.
    ///   - files: pack files already loaded (title screen); packs listed without files are presumed complete
    ///     for the seasons their name covers, so the review never needs a detail call.
    public static func review(
        _ title: LibraryTitle,
        schedule: EpisodeSchedule?,
        files: [ShelfItem.ID: [LibraryFile]] = [:],
        dismissals: ReviewDismissals = ReviewDismissals(),
        now: Date = .now
    ) -> TitleReview {
        var review = TitleReview(titleID: title.id)
        // A failed item holds nothing; one still downloading is on its way.
        let items = title.items.filter { LibraryFilter.Status(of: $0.item.status) != .failed }
        guard !items.isEmpty else { return review }

        if title.type == .movie {
            let qualities = items.map { ReleaseQuality(name: $0.name) }
            if let best = qualities.max(by: ReleaseQuality.worse), best.isWeak, dismissals.quality[title.id] != best.label {
                review.weak = [TitleReview.WeakSpot(season: nil, quality: best)]
            }
            return review
        }

        let media = title.media ?? MediaSummary(id: title.id, type: .series, name: title.name)
        let detail = schedule?.detail(for: media)
        let layout = SeriesLayout(items: items, files: files, detail: detail, now: now)

        // Quality: per season, the worst episode's preferred version.
        let accepted = dismissals.quality[title.id]
        for season in layout.seasons where season.number > 0 {
            let qualities = season.available.compactMap { $0.files.first }.map { ReleaseQuality(file: $0.name, release: $0.item.name) }
            if let worst = qualities.min(by: ReleaseQuality.worse), worst.isWeak, accepted != worst.label {
                review.weak.append(TitleReview.WeakSpot(season: season.number, quality: worst))
            }
        }

        guard let detail else { return review }
        var held = Set(layout.available.map { key(season: $0.season, number: $0.number) })
        for item in items where item.guess.scope?.isPack == true && item.item.files.isEmpty && files[item.id] == nil {
            // A pack added mid-season holds what had aired by then.
            let cutoff = item.item.addedAt.map { $0.addingTimeInterval(86_400) } ?? .distantFuture
            for episode in detail.episodes where covers(item.guess.scope, season: episode.season)
                && (episode.released ?? .distantPast) <= cutoff {
                held.insert(key(season: episode.season, number: episode.number))
            }
        }
        let regular = detail.episodes.filter { $0.season > 0 }.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        guard let last = regular.last(where: { held.contains(key(season: $0.season, number: $0.number)) }) else { return review }
        let dismissed = dismissals.episodes[title.id] ?? []
        let since = title.latestAdded
        let heldSeasons = Set(held.compactMap { Int($0.prefix { $0 != "x" }) })
        // Following the show: new episodes continue the last season held, or start the next one once that season
        // is complete. A show the user only sampled (S01 of thirteen) gets no "new" from today's season.
        let caughtUp = regular.allSatisfy { episode in
            episode.season != last.season || held.contains(key(season: episode.season, number: episode.number))
                || (episode.released ?? .distantPast) > now
        }

        for episode in regular {
            let id = key(season: episode.season, number: episode.number)
            guard !held.contains(id), !dismissed.contains(id) else { continue }
            let isAfter = (episode.season, episode.number) > (last.season, last.number)
            if let released = episode.released {
                guard released <= now else { continue }
                let follows = episode.season == last.season || (episode.season == last.season + 1 && caughtUp)
                if isAfter, follows, let since, released > since {
                    review.new.append(episode)
                } else if heldSeasons.contains(episode.season) {
                    review.missing.append(episode)
                } else {
                    review.unstarted.append(episode)
                }
            } else if !isAfter {
                // No date: aired if a later episode is held.
                if heldSeasons.contains(episode.season) { review.missing.append(episode) } else { review.unstarted.append(episode) }
            }
        }
        return review
    }

    private static func covers(_ scope: SeriesScope?, season: Int) -> Bool {
        switch scope {
        case .season(let number): number == season
        case .seasons(let first, let last): (first...last).contains(season)
        case .complete: season > 0
        case .episodes, nil: false
        }
    }

    /// "S03E04–E06, S04", for rows: a whole season (every aired episode of it listed) by number, else runs.
    public static func label(_ episodes: [Episode], schedule: EpisodeSchedule? = nil, now: Date = .now) -> String {
        let bySeason = Dictionary(grouping: episodes, by: \.season)
        return bySeason.keys.sorted().map { season in
            let numbers = Array(Set(bySeason[season]!.map(\.number))).sorted()
            let aired = schedule?.episodes.filter { $0.season == season && ($0.released ?? .distantPast) <= now }.count ?? 0
            let code = "S" + twoDigits(season)
            if aired > 1, numbers.count >= aired { return code }
            var runs: [String] = []
            var start = numbers[0], previous = numbers[0]
            for number in numbers.dropFirst() + [Int.max] {
                if number == previous + 1 { previous = number; continue }
                runs.append(code + "E" + twoDigits(start) + (previous == start ? "" : "–E" + twoDigits(previous)))
                start = number
                previous = number
            }
            return runs.joined(separator: ", ")
        }
        .joined(separator: ", ")
    }

    private static func twoDigits(_ number: Int) -> String { number < 10 ? "0\(number)" : String(number) }
}
