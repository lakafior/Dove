import Foundation
import Testing
@testable import DoveKit

struct PackCompletenessTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var show: MediaDetail {
        let past = now.addingTimeInterval(-86_400)
        let future = now.addingTimeInterval(86_400)
        var episodes = (1...10).map { Episode(id: "tt1:1:\($0)", season: 1, number: $0, released: past) }
        episodes += (1...8).map { Episode(id: "tt1:2:\($0)", season: 2, number: $0, released: $0 <= 5 ? past : future) }
        episodes.append(Episode(id: "tt1:0:1", season: 0, number: 1, released: past))
        episodes += (1...6).map { Episode(id: "tt1:3:\($0)", season: 3, number: $0, released: future) }
        return MediaDetail(summary: MediaSummary(id: "tt1", type: .series, name: "Show"), episodes: episodes)
    }

    private func pack(_ folder: String, episodeSize: Int64, folderSize: Int64?) -> StreamGroup {
        StreamGroup.group([
            StreamCandidate(
                id: folder, kind: .debrid, title: "Show.S01E01.1080p.mkv", size: episodeSize,
                folderName: folder, folderSize: folderSize, infoHash: folder
            )
        ])[0]
    }

    @Test func onlyAiredEpisodesAndSeasonsCount() {
        #expect(PackCompleteness.airedEpisodes(in: show, season: 2, now: now) == [1, 2, 3, 4, 5])
        #expect(PackCompleteness.airedSeasons(in: show, now: now) == [1, 2], "no specials, nothing unaired")
    }

    @Test func seasonPackEstimateWarnsOnlyWhenClearlyShort() {
        let complete = pack("Show.S01.1080p", episodeSize: 1_000, folderSize: 9_600)
        #expect(PackCompleteness.estimatedEpisodes(in: complete) == 10)
        #expect(PackCompleteness.seasonPackWarning(for: complete, aired: 10) == nil)

        // A long pilot makes the estimate 8 of 10: within the margin.
        let longPilot = pack("Show.S01.1080p", episodeSize: 1_250, folderSize: 10_000)
        #expect(PackCompleteness.seasonPackWarning(for: longPilot, aired: 10) == nil)

        let short = pack("Show.S01.1080p", episodeSize: 1_000, folderSize: 6_000)
        #expect(PackCompleteness.seasonPackWarning(for: short, aired: 10) == "Looks incomplete: about 6 of 10 episodes")

        let unknown = pack("Show.S01.1080p", episodeSize: 1_000, folderSize: nil)
        #expect(PackCompleteness.seasonPackWarning(for: unknown, aired: 10) == nil)
    }

    @Test func seriesPackWarnsAboutMissingSeasons() {
        let partial = pack("Show.S01-S02.1080p", episodeSize: 1, folderSize: 100)
        #expect(PackCompleteness.seriesPackWarning(for: partial, airedSeasons: [1, 2, 3, 4]) == "Seasons 1–2 of 4")
        #expect(PackCompleteness.seriesPackWarning(for: partial, airedSeasons: [1, 2]) == nil)
        let complete = pack("Show.Complete.Series.1080p", episodeSize: 1, folderSize: 100)
        #expect(PackCompleteness.seriesPackWarning(for: complete, airedSeasons: [1, 2]) == nil, "no seasons in the name")
    }

    private func item(_ id: String, _ name: String, files: [String] = []) -> ShelfItem {
        ShelfItem(item: LibraryItem(
            id: id, backend: .torBox, name: name, status: .ready,
            files: files.enumerated().map { LibraryFile(id: String($0.offset), name: $0.element) }
        ))
    }

    @Test func libraryCountsEpisodesFromNamesAndPackFiles() {
        let items = [
            item("a", "Show.S01E09.1080p.mkv"),
            item("b", "Show.S01.1080p", files: [
                "Show.S01/Show.S01E01.mkv", "Show.S01/Show.S01E02-E03.mkv", "Show.S01/Sample/Show.S01E04.sample.mkv",
            ]),
            item("c", "Show.S01-S02.720p"),
        ]
        let files = [items[2].id: [LibraryFile(id: "1", name: "S02/Show.S02E01.mkv"), LibraryFile(id: "2", name: "S01/Show.S01E05.mkv")]]

        #expect(PackCompleteness.episodes(inSeason: 1, items: items, files: files) == [1, 2, 3, 5, 9])
        #expect(PackCompleteness.episodes(inSeason: 2, items: items, files: files) == [1])
    }

    @Test func summaryListsWhatIsMissing() {
        #expect(PackCompleteness.summary(have: Set(1...10), aired: Array(1...10)) == "All 10 episodes")
        #expect(PackCompleteness.summary(have: [1, 2, 3, 5, 6, 8, 9, 10], aired: Array(1...10)) == "Missing E04, E07 · 8 of 10")
        #expect(PackCompleteness.summary(have: [], aired: Array(1...8)) == "Missing E01, E02, E03, E04, E05, E06 +2 · 0 of 8")
        #expect(PackCompleteness.summary(have: [1], aired: []) == nil)
    }
}
