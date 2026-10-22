import Foundation
import Testing
@testable import DoveKit

struct ContentClassifierTests {
    @Test(arguments: [
        // Video by markers, by a year, or by a season.
        ("Shrek.2001.UHD.BluRay.2160p.DTS-X.7.1.HEVC.REMUX-FraMeSToR", ContentKind.video),
        ("Dark Matter 2024 S02E01 A Quiet Life 2160p ATVP WEB.DL", .video),
        ("Severance.S01.2160p.ATVP.WEB-DL.DDP5.1.Atmos.DV.MP4.x265-DVSUX[rartv]", .video),
        ("The Office Complete Series", .video),
        ("Some Old Film (1972)", .video),
        // Single files are judged by their extension.
        ("BlackBerry.2023.REMUX.mkv", .video),
        ("Artist - Song.flac", .music),
        ("Some Book - Author.epub", .books),
        ("ubuntu-24.04-desktop-amd64.iso", .software),
        // Other kinds by markers.
        ("Pink Floyd - The Dark Side of the Moon (1973) [FLAC 24bit]", .music),
        ("Artist - Discography 2001-2020 [MP3 320kbps]", .music),
        ("Brandon Sanderson - Mistborn Trilogy (ePub)", .books),
        ("Cyberpunk 2077 v2.1 - GOG", .games),
        ("Some.Game-FitGirl.Repack", .games),
        ("Ubuntu 24.04 Desktop amd64", .software),
        // Adult markers win over video markers.
        ("Some.Site.24.03.01.Name.XXX.1080p.MP4-GRP", .adult),
        ("Studio - Title [XXX] 2160p", .adult),
        ("Xxxholic.S01E01.1080p", .video),
        // Nothing to go on.
        ("random stuff", .other),
    ])
    func byName(name: String, kind: ContentKind) {
        #expect(ContentClassifier.classify(name: name, files: []) == kind)
    }

    @Test func filesWeighedBySizeBeatTheName() {
        let game = [
            LibraryFile(id: "1", name: "Game/setup.iso", size: 40_000_000_000),
            LibraryFile(id: "2", name: "Game/trailer.mp4", size: 200_000_000),
        ]
        #expect(ContentClassifier.classify(name: "Game 2024 1080p Trailer Edition", files: game) == .software)

        let album = [
            LibraryFile(id: "1", name: "01.flac", size: 40_000_000),
            LibraryFile(id: "2", name: "02.flac", size: 40_000_000),
            LibraryFile(id: "3", name: "cover.jpg", size: 9_000_000),
        ]
        #expect(ContentClassifier.classify(name: "Album", files: album) == .music)
    }

    @Test func samplesDoNotCountAndExtrasAreIgnored() {
        let files = [
            LibraryFile(id: "1", name: "Movie/Sample/sample.mkv", size: 50_000_000),
            LibraryFile(id: "2", name: "Movie/movie.part1.rar", size: 4_000_000_000),
            LibraryFile(id: "3", name: "Movie/readme.pdf", size: 10_000),
        ]
        #expect(ContentClassifier.classify(name: "Movie", files: files) == .books, "only the pdf is classified")
        #expect(ContentClassifier.classify(name: "Movie", files: [files[1]]) == .other)
    }

    @Test func filesWithoutSizesCountOneEach() {
        let files = [LibraryFile(id: "1", name: "a.mp3"), LibraryFile(id: "2", name: "b.mp3"), LibraryFile(id: "3", name: "c.mkv")]
        #expect(ContentClassifier.classify(name: "x", files: files) == .music)
    }
}

struct SeriesScopeTests {
    @Test(arguments: [
        ("Show.S02E05.1080p.WEB", SeriesScope?.some(.episodes(season: 2, [5])), "S02E05"),
        ("Show.S01E01-E03.1080p", .some(.episodes(season: 1, [1, 2, 3])), "S01E01–E03"),
        ("Severance.S01.2160p.ATVP.WEB-DL", .some(.season(1)), "Season 1"),
        ("Show.S01-S05.1080p.BluRay", .some(.seasons(first: 1, last: 5)), "Seasons 1–5"),
        ("The.Office.Complete.Series.1080p", .some(.complete), "Complete series"),
        ("Dune.2021.2160p", nil, ""),
    ])
    func scope(name: String, scope: SeriesScope?, label: String) {
        let guess = ReleaseParser.guess(name)
        #expect(guess.scope == scope)
        #expect(guess.type == (scope == nil ? .movie : .series))
        #expect((scope?.label ?? "") == label)
    }

    private func title(_ names: [String]) -> LibraryTitle {
        let items = names.enumerated().map { index, name in
            ShelfItem(item: LibraryItem(id: "torrent:\(index)", backend: .torBox, name: name, status: .ready))
        }
        return LibraryTitle(id: "t", guess: items[0].guess, media: nil, items: items)
    }

    @Test func coverageSummarizesWhatTheLibraryHolds() {
        #expect(title(["Show.S02E05.1080p"]).coverage == "S02E05")
        #expect(title(["Show.S02E05.1080p", "Show.S02E06.1080p"]).coverage == "S2 · 2 ep")
        #expect(title(["Show.S01E01.1080p", "Show.S03E02.1080p"]).coverage == "2 ep")
        #expect(title(["Show.S01.1080p", "Show.S02.1080p", "Show.S03.1080p", "Show.S05.1080p"]).coverage == "S1–3, 5")
        #expect(title(["Show.S01.1080p", "Show.S01E04.720p", "Show.S02E01.1080p"]).coverage == "S1 +1 ep")
        #expect(title(["Show.S01-S03.1080p", "Show.Complete.Series.720p"]).coverage == "Complete")
        #expect(title(["Dune.2021.2160p"]).coverage == nil)
    }

    @Test func multiSeasonPacksComeFirstInTheirOwnGroup() {
        let groups = title(["Show.S02E01.1080p", "Show.S01-S03.1080p", "Show.S01.1080p"]).seasons
        #expect(groups.map(\.season) == [nil, 1, 2])
    }
}

struct LibraryKindShelfTests {
    @Test func onlyVideoBecomesTitlesAndTheRestIsListed() {
        let items = [
            ShelfItem(item: LibraryItem(id: "torrent:1", backend: .torBox, name: "Dune.2021.2160p", status: .ready)),
            ShelfItem(item: LibraryItem(id: "torrent:2", backend: .torBox, name: "Album [FLAC]", status: .ready)),
            ShelfItem(item: LibraryItem(id: "torrent:3", backend: .torBox, name: "random stuff", status: .ready)),
        ]
        #expect(LibraryShelf.titles(items, matches: [:]).map(\.name) == ["Dune"])
        #expect(LibraryShelf.others(items).map(\.kind) == [.other], "music is shelved by artist")
        #expect(LibraryShelf.albums(items, matches: [:]).map(\.name) == ["Album"])

        var filter = LibraryFilter()
        filter.category = .music
        #expect(filter.apply(to: items).map(\.item.id) == ["torrent:2"])
        #expect(filter.apply(to: LibraryShelf.titles(items, matches: [:])).isEmpty)
    }

    @Test func aKnownKindOverridesTheName() {
        let item = LibraryItem(id: "torrent:1", backend: .realDebrid, name: "Album 2020", status: .ready)
        #expect(ShelfItem(item: item).kind == .video)
        #expect(ShelfItem(item: item, kind: .music).kind == .music)
    }
}

struct KindOverridesTests {
    private let rd = LibraryItem(id: "torrent:1", backend: .realDebrid, name: "Dune.2021.2160p", status: .ready)

    @Test func manualBeatsLearnedBeatsTheClassifier() {
        var overrides = KindOverrides()
        #expect(overrides.kind(of: rd) == .video)
        overrides.learned["realDebrid/torrent:1"] = .music
        #expect(overrides.kind(of: rd) == .music)
        overrides.manual["realDebrid/torrent:1"] = .adult
        #expect(overrides.shelfItem(rd).kind == .adult)
        #expect(ShelfItem(item: rd).id == "realDebrid/torrent:1")
    }

    @Test func oldLearnedKindsFileIsReadAndUnknownKindsAreDropped() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "dove-kinds-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"realDebrid/torrent:1":"music","torbox/torrent:2":"hologram"}"#.utf8).write(to: file)
        #expect(KindOverrides.load(from: file) == KindOverrides(learned: ["realDebrid/torrent:1": .music]))

        let saved = KindOverrides(learned: ["a": .books], manual: ["b": .adult])
        try saved.save(to: file)
        #expect(KindOverrides.load(from: file) == saved)
    }

    @Test func adultLibraryCategoryAndNewznabCategory() {
        let item = ShelfItem(item: LibraryItem(id: "t", backend: .torBox, name: "x", status: .ready), kind: .adult)
        var filter = LibraryFilter()
        filter.category = .adult
        #expect(filter.apply(to: [item]).count == 1)
        #expect(LibraryShelf.titles([item], matches: [:]).isEmpty)
        #expect(ContentKind(newznabCategory: 6010) == .adult)
        #expect(NewznabCategory.adult.ids == [6000])
    }
}

struct AddCategoryTests {
    @Test func categoriesFromSearchAndNames() {
        #expect(AddCategory(mediaType: .movie) == .movies)
        #expect(AddCategory(mediaType: .series) == .tv)
        #expect([2040, 5030, 3010, 4050, 6010, 7020].compactMap(AddCategory.init(newznabCategory:)) == [.movies, .tv, .audio, .games, .xxx, .books])
        #expect(AddCategory(newznabCategory: 3030) == .audiobooks)
        #expect(AddCategory(newznabCategory: 8010) == nil)
        #expect(AddCategory(releaseName: "Pink Floyd - The Wall (1979) [FLAC]") == .audio)
        #expect(AddCategory(releaseName: "Clip.XXX.1080p.nzb") == .xxx)
        #expect(AddCategory(releaseName: "Ubuntu 24.04 Desktop amd64") == .software)
    }
}

