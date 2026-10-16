import Foundation
import Testing
@testable import DoveKit

struct WatchlistTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var day: TimeInterval { 86_400 }
    private let dune = MediaSummary(id: "tmdb:693134", type: .movie, name: "Dune: Part Two", releaseInfo: "2024")
    private let show = MediaSummary(id: "tt1", type: .series, name: "Show", releaseInfo: "2021")

    @Test func addingRemembersEveryIDAndDoesNotRepeat() {
        var list = Watchlist()
        list.add(dune, now: now)
        list.add(MediaSummary(id: "tt15239678", type: .movie, name: "Dune: Part Two"), otherIDs: ["tmdb:693134"], now: now)
        #expect(list.entries.count == 1)
        #expect(list.contains(MediaSummary(id: "tt15239678", type: .movie, name: "x")), "the detail's IMDb ID is learned")
        list.add(show, now: now)
        #expect(list.entries.map(\.id) == ["tt1", "tmdb:693134"], "newest first")
        list.remove(MediaSummary(id: "tt15239678", type: .movie, name: ""))
        #expect(list.entries.map(\.id) == ["tt1"])
    }

    @Test func entriesFindTheirLibraryTitleByIDOrNameAndYear() {
        let item = ShelfItem(item: LibraryItem(id: "1", backend: .torBox, name: "Dune.Part.Two.2024.2160p.WEB-DL", status: .ready))
        let byID = LibraryTitle(id: "a", guess: item.guess, media: dune, items: [item])
        let byName = LibraryTitle(id: "b", guess: item.guess, media: nil, items: [item])
        let entry = Watchlist.Entry(media: dune)
        #expect(Watchlist.title(for: entry, in: [byID])?.id == "a")
        #expect(Watchlist.title(for: entry, in: [byName])?.id == "b", "guessed name and year")
        #expect(Watchlist.title(for: Watchlist.Entry(media: show), in: [byID, byName]) == nil)
    }

    @Test func seriesShowNewEpisodesSinceAddedThenTheNextOne() {
        let entry = Watchlist.Entry(media: show, addedAt: now.addingTimeInterval(-day * 10))
        let episodes = [
            (1, 1, -100.0), (1, 2, -5.0), (1, 3, -1.0), (1, 4, 3.0),
        ].map { Episode(id: "tt1:\($0.0):\($0.1)", season: $0.0, number: $0.1, released: now.addingTimeInterval(day * $0.2)) }
        let schedule = EpisodeSchedule(detail: MediaDetail(summary: show, episodes: episodes), fetchedAt: now)
        let status = WatchlistStatus.of(entry, inLibrary: false, schedule: schedule, now: now)
        #expect(status?.label(now: now) == "2 new · S01E03")
        #expect(status?.announcement == "new:1x3")

        let caughtUp = Watchlist.Entry(media: show, addedAt: now)
        let next = WatchlistStatus.of(caughtUp, inLibrary: false, schedule: schedule, now: now)
        #expect(next == .nextEpisode(episodes[3]))
        #expect(next?.announcement == nil)
        #expect(WatchlistStatus.of(entry, inLibrary: true, review: nil, schedule: schedule, now: now)?.label() == "In library")
    }

    @Test func moviesFollowTheirReleaseDates() {
        let entry = Watchlist.Entry(media: dune)
        func status(_ release: MovieRelease) -> WatchlistStatus? { WatchlistStatus.of(entry, inLibrary: false, release: release, now: now) }
        let past = now.addingTimeInterval(-day * 30), soon = now.addingTimeInterval(day * 20)
        #expect(status(MovieRelease(theatrical: past, digital: past.addingTimeInterval(day))) == .out(since: past.addingTimeInterval(day)))
        #expect(status(MovieRelease(theatrical: past, digital: past.addingTimeInterval(day)))?.announcement == "out")
        #expect(status(MovieRelease(theatrical: past, digital: soon)) == .digitalOn(soon))
        #expect(status(MovieRelease(theatrical: past)) == .inTheaters(since: past))
        #expect(status(MovieRelease(theatrical: soon)) == .theatricalOn(soon))
        #expect(status(MovieRelease()) == nil)
        #expect(WatchlistStatus.of(entry, inLibrary: false, release: nil, now: now) == nil)
    }

    @Test func releaseDatesPreferTheUSAndFallBackToTheEarliest() async throws {
        let transport = MockTransport()
        await transport.stub("3/movie/693134/release_dates", json: """
        {"id":693134,"results":[
          {"iso_3166_1":"PL","release_dates":[{"type":3,"release_date":"2024-02-28T00:00:00.000Z"},{"type":4,"release_date":"2024-04-10T00:00:00.000Z"}]},
          {"iso_3166_1":"US","release_dates":[{"type":3,"release_date":"2024-03-01T00:00:00.000Z"},{"type":1,"release_date":"2024-02-15T00:00:00.000Z"}]},
          {"iso_3166_1":"DE","release_dates":[{"type":5,"release_date":"2024-06-20T00:00:00.000Z"}]}
        ]}
        """)
        let release = try await TMDBMetadata(key: "0123456789abcdef0123456789abcdef", transport: transport).releaseDates(of: dune)
        #expect(release.theatrical == TMDBMetadata.parseTimestamp("2024-03-01T00:00:00.000Z"), "the US theatrical date, not Poland's earlier one")
        #expect(release.digital == TMDBMetadata.parseTimestamp("2024-04-10T00:00:00.000Z"), "no US digital date: the earliest anywhere")
        #expect(release.physical == TMDBMetadata.parseTimestamp("2024-06-20T00:00:00.000Z"))
        #expect(release.theatrical != nil)
    }

    @Test func theWatchlistTravelsInSettingsExportsWithoutSecrets() {
        #expect(CredentialKey.watchlist.sensitivity == .setting)
    }
}
