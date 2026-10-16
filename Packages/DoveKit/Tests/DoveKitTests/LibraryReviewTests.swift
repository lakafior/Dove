import Foundation
import Testing
@testable import DoveKit

struct LibraryReviewTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var day: TimeInterval { 86_400 }

    private func item(_ name: String, files: [String] = [], status: LibraryItem.Status = .ready, added: Date? = nil) -> ShelfItem {
        let list = files.enumerated().map { LibraryFile(id: String($0.offset), name: $0.element, size: 1) }
        return ShelfItem(item: LibraryItem(id: UUID().uuidString, backend: .torBox, name: name, status: status, files: list, addedAt: added))
    }

    private func title(_ items: [ShelfItem], type: MediaType = .series) -> LibraryTitle {
        LibraryTitle(id: "media:\(type.rawValue):tt1", guess: items[0].guess,
                     media: MediaSummary(id: "tt1", type: type, name: "Show"), items: items)
    }

    /// Seasons of `count` episodes, one a week, the last aired `lastAired` days ago; `upcoming` more per season later.
    private func schedule(_ seasons: [Int: Int], aired: [Int: [Date]] = [:], upcoming: Int = 0) -> EpisodeSchedule {
        var episodes: [Episode] = []
        for (season, count) in seasons {
            for number in 1...(count + upcoming) {
                let released = aired[season]?[safe: number - 1]
                    ?? (number > count ? now.addingTimeInterval(day * 3) : now.addingTimeInterval(-day * 400))
                episodes.append(Episode(id: "tt1:\(season):\(number)", season: season, number: number, released: released))
            }
        }
        return EpisodeSchedule(detail: MediaDetail(summary: MediaSummary(id: "tt1", type: .series, name: "Show"), episodes: episodes), fetchedAt: now)
    }

    @Test func newEpisodesAiredSinceTheLastAddAndGapsBeforeIt() {
        let added = now.addingTimeInterval(-day * 30)
        let items = [
            item("Show.S01.1080p.WEB-DL-GRP", files: (1...8).filter { $0 != 4 }.map { "Show.S01E0\($0).1080p.mkv" }, added: added),
            item("Show.S02E01.1080p.WEB-DL-GRP", added: added),
            item("Show.S02E02.1080p.WEB-DL-GRP", added: added),
        ]
        // Season 2: E03 aired before the last add (missing), E04–E05 after it (new), E06 next week.
        let s2 = [-60.0, -50, -40, -10, -3].map { now.addingTimeInterval(day * $0) }
        let review = LibraryReview.review(title(items), schedule: schedule([1: 8, 2: 5], aired: [2: s2], upcoming: 0), now: now)
        #expect(review.missing.map(\.id) == ["tt1:1:4", "tt1:2:3"])
        #expect(review.new.map(\.id) == ["tt1:2:4", "tt1:2:5"])
        #expect(review.episodeSummary == "2 new · missing 2")
        #expect(LibraryReview.label(review.new) == "S02E04–E05")
    }

    @Test func newEpisodesOnlyForShowsTheUserFollows() {
        let added = now.addingTimeInterval(-day * 30)
        let recent = [now.addingTimeInterval(-day * 10), now.addingTimeInterval(-day * 3)]
        let shows = schedule([1: 3, 2: 2, 5: 2], aired: [5: recent])
        // Only S01: the airing S05 is not "new".
        var review = LibraryReview.review(title([item("Show.S01.1080p.WEB", added: added)]), schedule: shows, now: now)
        #expect(review.new.isEmpty)
        // Caught up on S01: S02 starting after the add is new.
        let s2 = schedule([1: 3, 2: 2], aired: [2: recent])
        review = LibraryReview.review(title([item("Show.S01.1080p.WEB", added: added)]), schedule: s2, now: now)
        #expect(review.new.map(\.id) == ["tt1:2:1", "tt1:2:2"])
    }

    @Test func packsWithoutFilesArePresumedCompleteUpToTheirAddDate() {
        let added = now.addingTimeInterval(-day * 20)
        // RD lists the season pack without files; S01 has 10 aired, the last two after the add.
        let aired = (1...10).map { now.addingTimeInterval(day * Double($0 <= 8 ? -100 + $0 : -10 + $0)) }
        let review = LibraryReview.review(title([item("Show.S01.1080p.BluRay", added: added)]),
                                          schedule: schedule([1: 10], aired: [1: aired]), now: now)
        #expect(review.missing.isEmpty)
        #expect(review.new.map(\.number) == [9, 10])
    }

    @Test func unstartedSeasonsAreMissingNotNewAndDismissalsHideThem() {
        let items = [item("Show.S01.1080p.WEB-DL", added: now.addingTimeInterval(-day * 300))]
        let shows = schedule([1: 3, 2: 3])
        var review = LibraryReview.review(title(items), schedule: shows, now: now)
        #expect(review.new.isEmpty)
        #expect(!review.hasEpisodes, "a season never started is not a gap")
        #expect(LibraryReview.label(review.unstarted, schedule: shows, now: now) == "S02")

        var dismissals = ReviewDismissals()
        dismissals.episodes["media:series:tt1"] = Set(review.unstarted.map { LibraryReview.key(season: $0.season, number: $0.number) })
        review = LibraryReview.review(title(items), schedule: shows, dismissals: dismissals, now: now)
        #expect(review.isEmpty)
    }

    @Test func futureAndUndatedEpisodesAfterTheLastHeldOneAreIgnored() {
        var shows = schedule([1: 2], upcoming: 2)
        shows.episodes.append(.init(id: "tt1:1:9", season: 1, number: 9, title: nil, released: nil))
        let review = LibraryReview.review(title([item("Show.S01.1080p.WEB", added: now)]), schedule: shows, now: now)
        #expect(review.isEmpty)
    }

    @Test func failedItemsHoldNothing() {
        let items = [item("Show.S01E01.720p.HDTV", status: .failed(reason: "x"))]
        #expect(LibraryReview.review(title(items), schedule: schedule([1: 3]), now: now).isEmpty)
    }

    @Test func weakQualityPerSeasonAndForMovies() {
        let items = [
            item("Show.S01.2160p.WEB-DL.DV-GRP", files: ["Show.S01E01.mkv", "Show.S01E02.mkv"]),
            item("Show.S02.720p.HDTV.x264-GRP", files: ["Show.S02E01.mkv", "Show.S02E02.mkv"]),
            item("Show.S02E02.1080p.WEB-DL-GRP"),
        ]
        let review = LibraryReview.review(title(items), schedule: nil, now: now)
        #expect(review.weak.map(\.season) == [2])
        #expect(review.qualitySummary == "S2: 720p")

        let movie = title([item("Movie.2020.1080p.WEB-DL.AV1-GRP"), item("Movie.2020.720p.BluRay-GRP")], type: .movie)
        #expect(LibraryReview.review(movie, schedule: nil).qualitySummary == "720p", "the clean 720p beats a 1080p AV1 on Apple TV")
        #expect(LibraryReview.review(title([item("Movie.2020.2160p.BluRay.REMUX.TrueHD.Atmos-GRP")], type: .movie), schedule: nil).isEmpty)
        #expect(LibraryReview.review(title([item("Movie.2020.2160p.WEB-DL.AV1-GRP")], type: .movie), schedule: nil).qualitySummary == "AV1")
        var dismissals = ReviewDismissals()
        dismissals.quality[movie.id] = "720p BluRay"
        #expect(LibraryReview.review(movie, schedule: nil, dismissals: dismissals).isEmpty)
        #expect(LibraryReview.review(title([item("Movie.2020.2160p.BluRay.REMUX-GRP")], type: .movie), schedule: nil).isEmpty)
    }

    @Test func upgradesBeatTheHeldQuality() {
        let held = ReleaseQuality(name: "Movie.2020.1080p.WEB-DL.DDP5.1-GRP")
        #expect(ReleaseQuality(name: "Movie.2020.2160p.WEB-DL.DV-GRP").isUpgrade(over: held))
        #expect(ReleaseQuality(name: "Movie.2020.1080p.BluRay.REMUX-GRP").isUpgrade(over: held))
        #expect(ReleaseQuality(name: "Movie.2020.1080p.HDR.WEB-DL-GRP").isUpgrade(over: held))
        #expect(!ReleaseQuality(name: "Movie.2020.1080p.WEBRip-GRP").isUpgrade(over: held))
        #expect(!ReleaseQuality(name: "Movie.2020.720p.BluRay-GRP").isUpgrade(over: held))
        #expect(!ReleaseQuality(name: "Movie.2020.2160p.WEB-DL.AV1-GRP").isUpgrade(over: held), "trades one problem for another")
        #expect(!ReleaseQuality(name: "Movie.2020.HDCAM").isUpgrade(over: held))

        let av1 = ReleaseQuality(name: "Movie.2020.2160p.WEB-DL.AV1-GRP")
        #expect(ReleaseQuality(name: "Movie.2020.2160p.WEB-DL.HEVC-GRP").isUpgrade(over: av1))
    }

    @Test func schedulesRefreshAfterTheirMaximumAge() async {
        let store = EpisodeScheduleStore(fileURL: nil)
        #expect(await store.needsRefresh("tt1", now: now))
        await store.set(schedule([1: 1]), for: "tt1")
        #expect(await !store.needsRefresh("tt1", now: now.addingTimeInterval(3600)))
        #expect(await store.needsRefresh("tt1", now: now.addingTimeInterval(EpisodeScheduleStore.maxAge + 1)))
        await store.prune(keeping: [])
        #expect(await store.all().isEmpty)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
