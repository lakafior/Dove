import Foundation
import Testing
@testable import DoveKit

struct BookGuessTests {
    @Test(arguments: [
        ("Andy Weir - Project Hail Mary (2021) [epub]", "Project Hail Mary", "Andy Weir", 2021),
        ("Andy Weir - Project Hail Mary.epub", "Project Hail Mary", "Andy Weir", nil),
        ("Brandon.Sanderson.-.Mistborn.The.Final.Empire.RETAIL.EPUB.eBook-GROUP", "Mistborn The Final Empire", "Brandon Sanderson", nil),
        ("Project Hail Mary by Andy Weir (Unabridged) [Ray Porter]", "Project Hail Mary", "Andy Weir", nil),
        ("Andy Weir - Project Hail Mary - Read by Ray Porter - 64kbps", "Project Hail Mary", "Andy Weir", nil),
        ("George Orwell - 1984 (1949) [epub]", "1984", "George Orwell", 1949),
        ("Dune Messiah 1969 epub", "Dune Messiah", nil, 1969),
        ("Stephen King - The Dark Tower 01 - The Gunslinger.m4b", "The Dark Tower 01 - The Gunslinger", "Stephen King", nil),
    ] as [(String, String, String?, Int?)])
    func readsAuthorTitleAndYear(name: String, title: String, author: String?, year: Int?) {
        let guess = BookGuess(releaseName: name, format: .ebook)
        #expect(guess.title == title)
        #expect(guess.author == author)
        #expect(guess.year == year)
    }

    @Test func keySeparatesFormatsAndIgnoresSpelling() {
        let ebook = BookGuess(releaseName: "Andy.Weir.-.Project.Hail.Mary.epub", format: .ebook)
        let same = BookGuess(releaseName: "Andy Weir - Project Hail Mary (2021) [epub]", format: .ebook)
        let audio = BookGuess(releaseName: "Andy Weir - Project Hail Mary (Unabridged)", format: .audiobook)
        #expect(ebook.key == same.key)
        #expect(ebook.key == "ebook|andyweir|projecthailmary")
        #expect(audio.key == "audiobook|andyweir|projecthailmary")
        #expect(audio.query == "Andy Weir Project Hail Mary")
    }
}

struct BookMatcherTests {
    private let hailMary = BookSummary(id: "ol:1", title: "Project Hail Mary", authors: ["Andy Weir"], year: 2021)
    private let summary = BookSummary(id: "ol:2", title: "Summary of Andy Weir's Project Hail Mary", authors: ["Irb Media"])
    private let omnibus = BookSummary(id: "ol:3", title: "The Martian / Artemis / Project Hail Mary", authors: ["Andy Weir"])

    @Test func prefersTheSameTitleAndAuthor() {
        let guess = BookGuess(title: "Project Hail Mary", author: "Andy Weir", format: .ebook)
        #expect(BookMatcher.best([summary, omnibus, hailMary], for: guess) == hailMary)
    }

    @Test func rejectsATitleThatOnlyContainsTheGuessWithoutTheAuthor() {
        let guess = BookGuess(title: "Project Hail Mary", author: "Andy Weir", format: .ebook)
        #expect(BookMatcher.best([summary], for: guess) == nil)
        #expect(BookMatcher.best([omnibus], for: guess) == omnibus, "contains the title, same author")
    }

    @Test func handlesSwappedAuthorAndTitle() {
        let guess = BookGuess(releaseName: "Project Hail Mary - Andy Weir.epub", format: .ebook)
        #expect(BookMatcher.best([hailMary], for: guess) == hailMary)
    }

    @Test func findsTheAuthorInsideATitleWithoutOne() {
        let guess = BookGuess(title: "Andy Weir Project Hail Mary", format: .ebook)
        #expect(BookMatcher.best([summary, hailMary], for: guess) == hailMary)
    }

    @Test func matchesASubtitleAndASurname() {
        let mistborn = BookSummary(id: "ol:4", title: "Mistborn: The Final Empire", authors: ["Brandon Sanderson"])
        #expect(BookMatcher.best([mistborn], for: BookGuess(title: "Mistborn", author: "Sanderson", format: .ebook)) == mistborn)
        #expect(BookMatcher.best([mistborn], for: BookGuess(title: "Elantris", author: "Sanderson", format: .ebook)) == nil)
    }

    @Test func yearBreaksATie() {
        let reissue = BookSummary(id: "ol:5", title: "Project Hail Mary", authors: ["Andy Weir"], year: 2026)
        let guess = BookGuess(title: "Project Hail Mary", author: "Andy Weir", year: 2021, format: .ebook)
        #expect(BookMatcher.best([reissue, hailMary], for: guess) == hailMary)
    }
}

struct BookMetadataTests {
    @Test func openLibraryResultsGetWorkIDsCoversAndLinks() async throws {
        let transport = MockTransport()
        await transport.stub("search.json", body: try Fixture.data("openlibrary_search"))

        let books = try await BookMetadata(transport: transport).search("andy weir project hail mary", in: .openLibrary)

        #expect(books.map(\.id) == ["ol:OL21745884W", "ol:OL26086346W", "ol:OL36735881W"])
        #expect(books[0].title == "Project Hail Mary")
        #expect(books[0].authors == ["Andy Weir"])
        #expect(books[0].year == 2021)
        #expect(books[0].cover?.absoluteString == "https://covers.openlibrary.org/b/id/11200092-L.jpg")
        #expect(books[0].link?.absoluteString == "https://openlibrary.org/works/OL21745884W")
        #expect(books[1].cover == nil)

        let request = try #require(await transport.requests.first)
        let query = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first { $0.name == "q" }?.value == "andy weir project hail mary")
        #expect(query.first { $0.name == "fields" }?.value == "key,title,author_name,first_publish_year,cover_i")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == BookMetadata.userAgent)
    }

    @Test func audiobooksComeFromITunesWithLargeArtworkAndPlainText() async throws {
        let transport = MockTransport()
        await transport.stub("search", body: try Fixture.data("itunes_audiobook_search"))

        let books = try await BookMetadata(transport: transport).search("andy weir project hail mary", in: .appleAudiobooks)

        #expect(books.map(\.id) == ["itunes:1565808256", "itunes:1729184154"])
        #expect(books[0].title == "Project Hail Mary", "(Unabridged) is dropped")
        #expect(books[0].year == 2021)
        #expect(books[0].cover?.absoluteString.hasSuffix("/rm_image.jpg/600x600bb.jpg") == true)
        #expect(books[0].description?.hasPrefix("THE #1  NEW YORK TIMES") == true)
        #expect(books[0].description?.hasSuffix("\n\nMore & more.") == true)

        let request = try #require(await transport.requests.first)
        let query = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first { $0.name == "media" }?.value == "audiobook")
        #expect(query.first { $0.name == "entity" }?.value == "audiobook")
    }

    @Test func ebooksAreTracks() async throws {
        let transport = MockTransport()
        await transport.stub("search", json: """
        {"results":[{"trackId":42,"trackName":"Dune","artistName":"Frank Herbert",
        "trackViewUrl":"https://books.apple.com/book/id42","artworkUrl100":"https://x/100x100bb.jpg","releaseDate":"1965-08-01T07:00:00Z"}]}
        """)
        let books = try await BookMetadata(transport: transport).search("dune", in: .appleBooks)
        #expect(books == [BookSummary(
            id: "itunes:42", title: "Dune", authors: ["Frank Herbert"], year: 1965,
            cover: URL(string: "https://x/600x600bb.jpg"), link: URL(string: "https://books.apple.com/book/id42")
        )])
    }

    @Test func audiobooksFallBackToOpenLibraryWhenTheStoreHasNothingFitting() async throws {
        let transport = MockTransport()
        await transport.stub("search", json: #"{"results":[]}"#)
        await transport.stub("search.json", body: try Fixture.data("openlibrary_search"))
        let guess = BookGuess(releaseName: "Andy Weir - Project Hail Mary (Unabridged)", format: .audiobook)

        let book = try await BookMetadata(transport: transport).match(guess)

        #expect(book?.id == "ol:OL21745884W")
        #expect(await transport.requests.map { $0.url!.host() } == ["itunes.apple.com", "openlibrary.org"])
    }

    @Test func appleRateLimitIsNotAKeyError() async throws {
        let transport = MockTransport()
        await transport.stub("search", status: 403, json: "{}")
        await #expect(throws: BackendError.rateLimited) {
            try await BookMetadata(transport: transport).search("dune", in: .appleBooks)
        }
    }

    @Test func pickerSearchKeepsWhatOneSourceFoundWhenTheOtherFails() async throws {
        let transport = MockTransport()
        await transport.stub("search", status: 500, json: "{}")
        await transport.stub("search.json", body: try Fixture.data("openlibrary_search"))
        let books = try await BookMetadata(transport: transport).search("project hail mary", format: .audiobook)
        #expect(books.count == 3)
    }
}

struct BookShelfTests {
    private func item(_ id: String, _ name: String, backend: BackendID = .torBox, added: TimeInterval = 0) -> LibraryItem {
        LibraryItem(id: id, backend: backend, name: name, status: .ready, addedAt: Date(timeIntervalSince1970: added))
    }

    @Test func classifiesAudiobooks() {
        #expect(ContentClassifier.classify(name: "Andy Weir - Project Hail Mary (Unabridged)", files: []) == .audiobooks)
        #expect(ContentClassifier.classify(name: "Project Hail Mary.m4b", files: []) == .audiobooks)
        let mp3s = [LibraryFile(id: "1", name: "Chapter 01.mp3", size: 50), LibraryFile(id: "2", name: "Chapter 02.mp3", size: 50)]
        #expect(ContentClassifier.classify(name: "Andy Weir - Project Hail Mary [Audiobook]", files: mp3s) == .audiobooks)
        #expect(ContentClassifier.classify(name: "Daft Punk - Discovery", files: mp3s) == .music)
        #expect(ContentKind(newznabCategory: 3030) == .audiobooks)
        #expect(ContentKind(newznabCategory: 3010) == .music)
        #expect(AddCategory(releaseName: "Andy Weir - Project Hail Mary (Unabridged).nzb") == .audiobooks)
    }

    @Test func groupsReleasesOfOneBookPerFormatAndLeavesThemOutOfOthers() {
        let items = [
            ShelfItem(item: item("1", "Andy Weir - Project Hail Mary (2021) [epub]", added: 3)),
            ShelfItem(item: item("2", "Andy.Weir.-.Project.Hail.Mary.RETAIL.EPUB", backend: .offcloud, added: 1)),
            ShelfItem(item: item("3", "Andy Weir - Project Hail Mary (Unabridged)", added: 2)),
            ShelfItem(item: item("4", "Daft Punk - Discovery FLAC", added: 4)),
        ]
        let match = BookSummary(id: "ol:OL21745884W", title: "Project Hail Mary", authors: ["Andy Weir"], year: 2021)

        let books = LibraryShelf.books(items, matches: ["ebook|andyweir|projecthailmary": match])

        #expect(books.map(\.format) == [.ebook, .audiobook])
        #expect(books[0].id == "book:ebook:ol:OL21745884W")
        #expect(books[0].items.map(\.item.id) == ["1", "2"])
        #expect(books[0].backends == [.offcloud, .torBox])
        #expect(books[0].year == "2021")
        #expect(books[1].book == nil)
        #expect(books[1].name == "Project Hail Mary")
        #expect(books[1].author == "Andy Weir")
        #expect(LibraryShelf.others(items).map(\.item.id) == ["4"])
    }

    @Test func filterPicksTheFormatAndSearchesAuthors() {
        let items = [
            ShelfItem(item: item("1", "Andy Weir - Project Hail Mary [epub]")),
            ShelfItem(item: item("2", "Andy Weir - The Martian (Unabridged)")),
        ]
        let books = LibraryShelf.books(items, matches: [:])
        var filter = LibraryFilter()
        filter.category = .audiobooks
        #expect(filter.apply(to: books).map(\.name) == ["The Martian"])
        filter.category = .movies
        #expect(filter.apply(to: books).isEmpty)
        filter = LibraryFilter()
        filter.query = "weir"
        #expect(filter.apply(to: books).count == 2)
        filter.query = "martian"
        #expect(filter.apply(to: books).map(\.name) == ["The Martian"])
    }

    @Test func bookMatchesUseTheSharedMatcherAndStore() async {
        let store = MetadataStore<BookSummary>(fileURL: nil)
        let guess = BookGuess(title: "Project Hail Mary", author: "Andy Weir", format: .ebook)
        let book = BookSummary(id: "ol:1", title: "Project Hail Mary", authors: ["Andy Weir"])
        let looked = await LibraryMatcher.matchMissing([guess.key: guess], store: store) { _ in book }
        #expect(looked == 1)
        #expect(await store.entry(for: guess.key) == .matched(book))
        #expect(await LibraryMatcher.matchMissing([guess.key: guess], store: store) { _ in book } == 0)
    }
}

struct BookFilesTests {
    private func item(_ id: String, _ files: [(String, Int64?)]) -> LibraryItem {
        LibraryItem(id: id, backend: .torBox, name: id, status: .ready,
                    files: files.enumerated().map { LibraryFile(id: "\($0.offset)", name: $0.element.0, size: $0.element.1) })
    }

    private let mixed = [
        ("Andy Weir - Project Hail Mary/cover.jpg", 200_000),
        ("Andy Weir - Project Hail Mary/Project Hail Mary.mobi", 3_000_000),
        ("Andy Weir - Project Hail Mary/Project Hail Mary.pdf", 9_000_000),
        ("Andy Weir - Project Hail Mary/Project Hail Mary.epub", 2_000_000),
        ("Andy Weir - Project Hail Mary/info.nfo", 1_000),
    ] as [(String, Int64?)]

    @Test func prefersEpubForBothTargets() throws {
        for target in ReadingTarget.allCases {
            let pick = try BookFiles.pick(from: [item("a", mixed)], for: target).get()
            #expect(pick.file.name.hasSuffix(".epub"))
        }
    }

    @Test func bestFormatWinsAcrossReleasesThenTheEarlierRelease() throws {
        let pdfOnly = item("pdf", [("Book.pdf", 1_000)])
        let epub = item("epub", [("Book.epub", 1_000)])
        let other = item("epub2", [("Book.epub", 1_000)])
        #expect(try BookFiles.pick(from: [pdfOnly, epub, other], for: .appleBooks).get().item.id == "epub")
    }

    @Test func refusesMobiAndAzw3WithTheirNames() {
        let kindleOnly = item("a", [("Book.azw3", 1_000), ("Book.mobi", 1_000), ("cover.jpg", 1)])
        #expect(BookFiles.pick(from: [kindleOnly], for: .kindle) == .failure(.unsupported(formats: ["AZW3", "MOBI"])))
        #expect(BookFiles.pickAny(from: [kindleOnly])?.file.name == "Book.azw3")
    }

    @Test func kindleSkipsFilesOverTheMailLimit() throws {
        let big = item("a", [("Book.pdf", 80_000_000), ("Book.docx", 1_000_000)])
        #expect(try BookFiles.pick(from: [big], for: .kindle).get().file.name == "Book.docx")
        #expect(try BookFiles.pick(from: [big], for: .appleBooks).get().file.name == "Book.pdf")
        let onlyBig = item("b", [("Book.pdf", 80_000_000)])
        #expect(BookFiles.pick(from: [onlyBig], for: .kindle) == .failure(.tooLarge(size: 80_000_000)))
    }

    @Test func nothingToReadWithoutFiles() {
        #expect(BookFiles.pick(from: [item("a", [])], for: .appleBooks) == .failure(.noBookFile))
        #expect(BookFiles.pick(from: [item("a", [("sample.epub", 1)])], for: .appleBooks) == .failure(.noBookFile))
    }

    @Test(arguments: [
        ("me@kindle.com", true), (" me@kindle.com ", true), ("me@kindle", false), ("me kindle.com", false),
        ("@kindle.com", false), ("me@@kindle.com", false), ("me@kindle..com", false),
    ])
    func validatesAddresses(address: String, valid: Bool) {
        #expect(BookFiles.isValidAddress(address) == valid)
    }

    @Test func cachePathsAreSafeAndKeepTheFileName() {
        let cache = BookFileCache(directory: URL(filePath: "/tmp/books"))
        let pick = BookFiles.Pick(item: LibraryItem(id: "link:https://x.y/a?b", backend: .allDebrid, name: "x", status: .ready),
                                  file: LibraryFile(id: "1", name: "Folder/Project Hail Mary.epub"))
        let url = cache.url(for: pick)
        #expect(url.lastPathComponent == "Project Hail Mary.epub")
        #expect(url.deletingLastPathComponent().lastPathComponent == "link_https___x.y_a_b")
    }
}

struct AudiobookTests {
    private func files(_ names: [String]) -> [LibraryFile] {
        names.enumerated().map { LibraryFile(id: "f\($0.offset)", name: $0.element) }
    }

    @Test func tracksFollowNaturalOrderAcrossFolders() throws {
        let tracks = try AudiobookTracks.tracks(in: files([
            "Book/CD2/01 - Part.mp3", "Book/CD1/10 - Part.mp3", "Book/CD1/2 - Part.mp3", "Book/cover.jpg",
            "Book/CD1/1 - Part.mp3", "Book/sample.mp3", "Book/info.nfo",
        ])).get()
        #expect(tracks.map(\.path) == ["Book/CD1/1 - Part.mp3", "Book/CD1/2 - Part.mp3", "Book/CD1/10 - Part.mp3", "Book/CD2/01 - Part.mp3"])
        #expect(tracks.first?.title == "1 - Part")
    }

    @Test func singleM4bIsOneTrack() throws {
        let tracks = try AudiobookTracks.tracks(in: files(["Andy Weir - Project Hail Mary.m4b", "cover.jpg"])).get()
        #expect(tracks.count == 1)
    }

    @Test func refusesWithoutPlayableAudio() {
        #expect(AudiobookTracks.tracks(in: files(["a.ogg", "b.opus"])) == .failure(.unplayable(formats: ["OGG", "OPUS"])))
        #expect(AudiobookTracks.tracks(in: files(["a.jpg"])) == .failure(.noAudio))
    }

    @Test func resumesByPathThenNameThenIndex() {
        let tracks = (0..<3).map { AudiobookTrack(fileID: "\($0)", path: "Release/0\($0).mp3") }
        #expect(AudiobookPosition(trackPath: "Release/02.mp3", trackIndex: 0, seconds: 12).resume(in: tracks) == (2, 12))
        #expect(AudiobookPosition(trackPath: "Other/01.mp3", trackIndex: 0, seconds: 5).resume(in: tracks) == (1, 5))
        #expect(AudiobookPosition(trackPath: "x.mp3", trackIndex: 2, seconds: 7).resume(in: tracks) == (2, 7))
        #expect(AudiobookPosition(trackPath: "x.mp3", trackIndex: 9, seconds: 7).resume(in: tracks) == (0, 0))
    }

    @Test func mergeKeepsTheNewerPositionAndRoundTrips() throws {
        var here = AudiobookPositions()
        here.set(AudiobookPosition(trackPath: "a", trackIndex: 0, seconds: 10, updatedAt: Date(timeIntervalSince1970: 100)), for: "book")
        var there = AudiobookPositions()
        there.set(AudiobookPosition(trackPath: "a", trackIndex: 0, seconds: 99, updatedAt: Date(timeIntervalSince1970: 200)), for: "book")
        there.set(AudiobookPosition(trackPath: "b", trackIndex: 0, seconds: 1, updatedAt: Date(timeIntervalSince1970: 50)), for: "other")
        here.merge(there)
        #expect(here["book"]?.seconds == 99)
        #expect(here["other"]?.trackPath == "b")
        let decoded = try JSONDecoder().decode(AudiobookPositions.self, from: JSONEncoder().encode(here))
        #expect(decoded == here)
    }

    @Test func clearingSurvivesAMergeWithAnOlderPosition() {
        var stored = AudiobookPositions()
        stored.set(AudiobookPosition(trackPath: "a", trackIndex: 0, seconds: 50, updatedAt: .now.addingTimeInterval(-60)), for: "book")
        stored.set(AudiobookPosition(trackPath: "b", trackIndex: 0, seconds: 5, updatedAt: .now.addingTimeInterval(-30)), for: "other")
        var here = stored
        here.set(nil, for: "book")
        #expect(here["book"] == nil)
        stored.merge(here)
        #expect(stored["book"] == nil)
        #expect(stored.listening.map(\.key) == ["other"])
        // Playing again after the clear is newer and wins.
        here.set(AudiobookPosition(trackPath: "a", trackIndex: 0, seconds: 1), for: "book")
        stored.merge(here)
        #expect(stored.listening.map(\.key) == ["book", "other"])
    }

    @Test func positionsFromBeforeClearingDecode() throws {
        let json = #"{"entries":{"book":{"trackPath":"a","trackIndex":1,"seconds":2,"updatedAt":0}}}"#
        let positions = try JSONDecoder().decode(AudiobookPositions.self, from: Data(json.utf8))
        #expect(positions["book"]?.trackIndex == 1)
    }

    @Test func dropsTheOldestOverTheLimit() {
        var positions = AudiobookPositions()
        for i in 0...AudiobookPositions.limit {
            positions.set(AudiobookPosition(trackPath: "", trackIndex: 0, seconds: 0, updatedAt: Date(timeIntervalSince1970: Double(i))), for: "\(i)")
        }
        #expect(positions.entries.count == AudiobookPositions.limit)
        #expect(positions["0"] == nil)
    }

    @Test func currentChapterIsTheLastStarted() {
        let chapters = [
            AudiobookChapter(trackIndex: 0, title: "One", start: 0, duration: 100),
            AudiobookChapter(trackIndex: 0, title: "Two", start: 100, duration: 100),
            AudiobookChapter(trackIndex: 1, title: "Three", start: 0, duration: nil),
        ]
        #expect(AudiobookChapter.current(in: chapters, trackIndex: 0, seconds: 150)?.title == "Two")
        #expect(AudiobookChapter.current(in: chapters, trackIndex: 0, seconds: 10)?.title == "One")
        #expect(AudiobookChapter.current(in: chapters, trackIndex: 1, seconds: 10)?.title == "Three")
    }
}
