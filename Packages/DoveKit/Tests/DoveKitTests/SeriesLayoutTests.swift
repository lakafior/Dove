import Foundation
import Testing
@testable import DoveKit

struct SeriesLayoutTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ name: String, id: String = UUID().uuidString, backend: BackendID = .torBox, status: LibraryItem.Status = .ready, files: [String] = [], size: Int64? = nil) -> ShelfItem {
        let list = files.enumerated().map { LibraryFile(id: String($0.offset), name: $0.element, size: size) }
        return ShelfItem(item: LibraryItem(id: id, backend: backend, name: name, size: size, status: status, files: list))
    }

    private func detail(seasons: [Int: Int], unaired: [Int: Int] = [:]) -> MediaDetail {
        let past = now.addingTimeInterval(-86_400)
        let future = now.addingTimeInterval(86_400)
        var episodes: [Episode] = []
        for (season, count) in seasons {
            let late = unaired[season] ?? 0
            for number in 1...(count + late) {
                episodes.append(Episode(id: "tt1:\(season):\(number)", season: season, number: number,
                                        title: "Ep \(number)", released: number > count ? future : past))
            }
        }
        episodes.append(Episode(id: "tt1:0:1", season: 0, number: 1, released: past))
        return MediaDetail(summary: MediaSummary(id: "tt1", type: .series, name: "Lost"), episodes: episodes)
    }

    @Test func locatesFilesBySceneCodeFolderAndLeadingNumber() {
        let release = ReleaseParser.guess("Lost.Complete.Series.1080p.BluRay")
        #expect(SeriesLayout.locate("Lost.S02E05.1080p.mkv", in: release)! == (2, [5]))
        #expect(SeriesLayout.locate("Season 3/Lost - 3x07 - Not in Portland.avi", in: release)! == (3, [7]))
        #expect(SeriesLayout.locate("Lost/Season 1/01 - Pilot (1).mkv", in: release)! == (1, [1]))
        #expect(SeriesLayout.locate("S04/Episode 12.mkv", in: release)! == (4, [12]))
        #expect(SeriesLayout.locate("Season 1/lost.104.x264.720p.mkv", in: release)! == (1, [4]), "codec and resolution are not episodes")
        #expect(SeriesLayout.locate("Lost.S01E01-E02.mkv", in: release)! == (1, [1, 2]))
        #expect(SeriesLayout.locate("Extras/Making of.mkv", in: release) == nil)
        // The season from the release name when there is no folder.
        #expect(SeriesLayout.locate("05 Pilot.mkv", in: ReleaseParser.guess("The.Office.US.S02.DVDRip"))! == (2, [5]))
    }

    @Test func packFilesBecomeSeasonsMergedWithMetadata() {
        let pack = item("The.Office.US.S01-S02.1080p", files: [
            "Season 1/The.Office.S01E01.mkv", "Season 1/The.Office.S01E02.mkv",
            "Season 2/The.Office.S02E01.mkv", "Season 2/Sample/sample.mkv", "Season 2/notes.nfo",
        ])
        let layout = SeriesLayout(items: [pack], detail: detail(seasons: [1: 3, 2: 2], unaired: [2: 1]), now: now)
        #expect(layout.seasons.map(\.number) == [1, 2], "specials only when held")
        #expect(layout.seasons[0].episodes.map(\.number) == [1, 2, 3])
        #expect(layout.seasons[0].episodes[2].isAvailable == false)
        #expect(layout.seasons[0].episodes[0].info?.title == "Ep 1")
        #expect(layout.seasons[1].episodes.map(\.number) == [1, 2], "unaired episode left out")
        #expect(layout.seasons[0].summary == "Missing E03 · 2 of 3")
        #expect(layout.available.map(\.code) == ["S01E01", "S01E02", "S02E01"])
        #expect(layout.unplaced.isEmpty)
    }

    @Test func singleEpisodesWithoutFilesAndPreferredVersion() {
        // Real-Debrid lists torrents without files: the item itself stands for its episode.
        let rd = item("Lost.S01E01.720p.HDTV", backend: .realDebrid)
        let pack = item("Lost.S01.1080p.BluRay", files: ["Lost.S01E01.1080p.mkv", "Lost.S01E02.1080p.mkv"])
        let failed = item("Lost.S01E02.2160p", status: .failed(reason: "dead"), files: ["Lost.S01E02.2160p.mkv"])
        let layout = SeriesLayout(items: [rd, pack, failed])
        let first = layout.seasons[0].episodes[0]
        #expect(first.files.count == 2)
        #expect(first.files[0].item.item.backend == .torBox, "1080p before 720p")
        #expect(first.files[1].file == nil)
        #expect(layout.seasons[0].episodes[1].files.first?.isReady == true, "ready before a better failed one")
        #expect(layout.seasons[0].summary == "All 2 episodes")
    }

    @Test func filesListedSeparatelyAreUsedAndUnplacedKept() {
        let rdPack = item("Lost.Complete.Series", id: "torrent:1", backend: .realDebrid)
        let files = [rdPack.id: [LibraryFile(id: "1", name: "Lost.S06E17.mkv"), LibraryFile(id: "2", name: "Bonus/Interview.mkv")]]
        let layout = SeriesLayout(items: [rdPack], files: files)
        #expect(layout.available.map(\.code) == ["S06E17"])
        #expect(layout.unplaced.map(\.name) == ["Bonus/Interview.mkv"])
    }

    @Test func playlistOrdersDedupesAndNamesForInfuse() {
        let pack = item("Lost.S01.1080p", files: ["Lost.S01E01-E02.mkv", "Lost.S01E03.mp4", "Lost.S01E04.mkv"])
        let layout = SeriesLayout(items: [pack])
        let episodes = layout.seasons[0].episodes
        let playlist = EpisodePlaylist(layout.available(from: episodes[1]), title: "Lost: Missing Pieces")
        #expect(playlist.entries.map(\.filename) == ["Lost Missing Pieces - S01E02.mkv", "Lost Missing Pieces - S01E03.mp4", "Lost Missing Pieces - S01E04.mkv"])

        let all = EpisodePlaylist(layout.available, title: "Lost")
        #expect(all.entries.map(\.episode.code) == ["S01E01", "S01E03", "S01E04"], "the double episode plays once")
    }
}
