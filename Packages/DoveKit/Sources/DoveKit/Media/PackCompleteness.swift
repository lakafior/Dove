import Foundation

/// Whether a season or series pack holds everything that has aired.
///
/// Before adding, addons give only the first episode's size and the pack's size, so the episode count is
/// an estimate (pack ÷ episode, with room for a longer pilot). In the library the files are known and the
/// answer is exact.
public enum PackCompleteness {
    /// Episode numbers of a season that have aired (no date counts as aired).
    public static func airedEpisodes(in detail: MediaDetail, season: Int, now: Date = .now) -> [Int] {
        detail.episodes(inSeason: season).filter { ($0.released ?? .distantPast) <= now }.map(\.number)
    }

    /// Regular seasons (no specials) with at least one aired episode.
    public static func airedSeasons(in detail: MediaDetail, now: Date = .now) -> [Int] {
        detail.seasons.filter { $0 > 0 && !airedEpisodes(in: detail, season: $0, now: now).isEmpty }
    }

    // MARK: - Source list (estimates)

    /// Episodes a season pack probably holds: its size over the listed episode's size.
    public static func estimatedEpisodes(in group: StreamGroup) -> Int? {
        guard let folder = group.folderSize, let episode = group.size, episode > 0, folder > episode else { return nil }
        return Int((Double(folder) / Double(episode)).rounded())
    }

    /// A warning when a season pack looks clearly short of the aired episodes. Lenient: a long pilot makes
    /// the estimate low, so it takes at least two missing episodes and under 80%.
    public static func seasonPackWarning(for group: StreamGroup, aired: Int) -> String? {
        guard aired > 1, let estimate = estimatedEpisodes(in: group) else { return nil }
        guard estimate <= aired - 2, Double(estimate) < Double(aired) * 0.8 else { return nil }
        return "Looks incomplete: about \(estimate) of \(aired) episodes"
    }

    /// A warning when a series pack's name covers fewer seasons than have aired.
    public static func seriesPackWarning(for group: StreamGroup, airedSeasons: [Int]) -> String? {
        let covered = Set(group.packSeasons)
        guard !covered.isEmpty, !airedSeasons.isEmpty else { return nil }
        let missing = airedSeasons.filter { !covered.contains($0) }
        guard !missing.isEmpty else { return nil }
        return "Seasons \(LibraryTitle.ranges(covered)) of \(airedSeasons.count)"
    }

    // MARK: - Library (exact)

    /// Episode numbers of `season` the items hold: single episodes by name, packs by their video files.
    /// - Parameter files: files of packs whose service did not list them with the item (Real-Debrid, Offcloud).
    public static func episodes(inSeason season: Int, items: [ShelfItem], files: [ShelfItem.ID: [LibraryFile]] = [:]) -> Set<Int> {
        var found = Set<Int>()
        for item in items {
            switch item.guess.scope {
            case .episodes(let itemSeason, let numbers):
                if itemSeason == season { found.formUnion(numbers) }
            case .season, .seasons, .complete:
                let packFiles = item.item.files.isEmpty ? files[item.id] ?? [] : item.item.files
                for file in packFiles where FileKind.isVideo(file.name) && !FileKind.isSample(file.name) {
                    if case .episodes(let fileSeason, let numbers) = ReleaseParser.guess(file.name).scope, fileSeason == season {
                        found.formUnion(numbers)
                    }
                }
            case nil:
                break
            }
        }
        return found
    }

    /// "All 10 episodes", or "Missing E04, E07 · 8 of 10". Nil when nothing has aired.
    public static func summary(have: Set<Int>, aired: [Int]) -> String? {
        guard !aired.isEmpty else { return nil }
        let missing = aired.filter { !have.contains($0) }
        if missing.isEmpty { return "All \(aired.count) episodes" }
        let shown = missing.prefix(6).map { "E" + ($0 < 10 ? "0\($0)" : String($0)) }.joined(separator: ", ")
        let more = missing.count > 6 ? " +\(missing.count - 6)" : ""
        return "Missing \(shown)\(more) · \(aired.count - missing.count) of \(aired.count)"
    }
}
