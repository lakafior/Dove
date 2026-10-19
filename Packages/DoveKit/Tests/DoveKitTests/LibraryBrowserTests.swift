import Foundation
import Testing
@testable import DoveKit

private actor BrowseBackend: LibraryBackend {
    nonisolated let id: BackendID
    nonisolated let supportedSources: Set<SourceKind> = [.torrent]
    var list: [LibraryItem]
    var detailed: [LibraryItem.ID: LibraryItem] = [:]
    var failing = false
    private(set) var listCalls = 0
    private(set) var detailCalls = 0
    private(set) var deleted: [LibraryItem.ID] = []

    init(id: BackendID, list: [LibraryItem], detailed: [LibraryItem] = []) {
        self.id = id
        self.list = list
        self.detailed = Dictionary(uniqueKeysWithValues: detailed.map { ($0.id, $0) })
    }

    func setFailing(_ value: Bool) { failing = value }
    func setList(_ items: [LibraryItem]) { list = items }

    func validateCredentials() async throws {}
    func add(_ source: Source) async throws -> LibraryItem.ID { "new" }
    func items() async throws -> [LibraryItem] {
        listCalls += 1
        if failing { throw BackendError.rateLimited }
        return list
    }
    func item(_ itemID: LibraryItem.ID) async throws -> LibraryItem {
        detailCalls += 1
        guard let item = detailed[itemID] ?? list.first(where: { $0.id == itemID }) else { throw BackendError.notFound }
        return item
    }
    func delete(_ itemID: LibraryItem.ID) async throws { deleted.append(itemID) }
    func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest {
        URLRequest(url: URL(string: "https://example.org/\(itemID)/\(fileID)")!)
    }
}

struct LibraryNodeIDTests {
    @Test(arguments: [
        LibraryNodeID.root,
        .backend(.torBox),
        .item(.realDebrid, "torrent:ABC123"),
        .folder(.nzbdav, "job:SABnzbd_nzo_1", path: "Show S01/Extras"),
        .file(.nzbdav, "dav:/content/tv/Show S01", "/content/tv/Show S01/a%20b.mkv"),
    ])
    func rawValueRoundTrips(_ id: LibraryNodeID) {
        #expect(LibraryNodeID(rawValue: id.rawValue) == id)
    }

    @Test func rejectsUnknownValues() {
        #expect(LibraryNodeID(rawValue: "x/torBox") == nil)
        #expect(LibraryNodeID(rawValue: "b/unknown") == nil)
        #expect(LibraryNodeID(rawValue: "f/torBox/1") == nil)
    }

    @Test func uniqueNamesNumberDuplicatesBeforeTheExtension() {
        let names = NodeNaming.unique([
            (key: "1", name: "Movie.mkv", isFolder: false),
            (key: "2", name: "movie.mkv", isFolder: false),
            (key: "3", name: "Pack", isFolder: true),
            (key: "4", name: "Pack", isFolder: true),
            (key: "5", name: "a/b", isFolder: false),
            (key: "6", name: "  ", isFolder: false),
        ])
        #expect(names == ["1": "Movie.mkv", "2": "movie (2).mkv", "3": "Pack", "4": "Pack (2)", "5": "a-b", "6": "Untitled"])
    }
}

struct LibraryBrowserTests {
    private let pack = LibraryItem(
        id: "job:1", backend: .nzbdav, name: "Show S01", status: .ready,
        files: [
            LibraryFile(id: "/c/Show S01/E01.mkv", name: "E01.mkv", size: 100),
            LibraryFile(id: "/c/Show S01/Extras/Making of.mkv", name: "Extras/Making of.mkv", size: 30),
            LibraryFile(id: "/c/Show S01/Extras/Deep/x.srt", name: "Extras/Deep/x.srt", size: 1),
        ]
    )

    @Test func rootListsConfiguredServices() async throws {
        let browser = LibraryBrowser(backends: [
            BrowseBackend(id: .realDebrid, list: []), BrowseBackend(id: .nzbdav, list: []),
        ])
        let root = try await browser.children(of: .root)
        #expect(root.map(\.name) == ["Real-Debrid", "nzbdav"])
        #expect(root.allSatisfy { $0.isFolder && $0.parent == .root })
    }

    @Test func serviceListsOnlyReadyItemsWithUniqueNames() async throws {
        let backend = BrowseBackend(id: .torBox, list: [
            LibraryItem(id: "torrent:1", backend: .torBox, name: "Movie", status: .ready),
            LibraryItem(id: "torrent:2", backend: .torBox, name: "Movie", status: .ready),
            LibraryItem(id: "torrent:3", backend: .torBox, name: "Busy", status: .downloading(progress: 0.5)),
        ])
        let browser = LibraryBrowser(backends: [backend])
        let items = try await browser.children(of: .backend(.torBox))
        #expect(items.map(\.name) == ["Movie", "Movie (2)"])
        #expect(items.allSatisfy { if case .item = $0.id { $0.parent == .backend(.torBox) } else { false } })
    }

    @Test func hiddenItemsAreLeftOutOfListsAndLookups() async throws {
        let backend = BrowseBackend(id: .torBox, list: [
            LibraryItem(id: "torrent:1", backend: .torBox, name: "Movie", status: .ready),
            LibraryItem(id: "torrent:2", backend: .torBox, name: "Clip.XXX.1080p", status: .ready),
        ])
        let browser = LibraryBrowser(backends: [backend], hides: { ContentClassifier.isAdult(name: $0.name) })
        #expect(try await browser.children(of: .backend(.torBox)).map(\.name) == ["Movie"])
        #expect(await browser.topLevel().nodes.map(\.name) == ["TorBox", "Movie"])
        await #expect(throws: BackendError.notFound) { try await browser.node(.item(.torBox, "torrent:2")) }
    }

    @Test func itemContentsBecomeFoldersFromFilePaths() async throws {
        let browser = LibraryBrowser(backends: [BrowseBackend(id: .nzbdav, list: [pack])])
        let top = try await browser.children(of: .item(.nzbdav, "job:1"))
        #expect(top.map(\.name) == ["Extras", "E01.mkv"])
        #expect(top[0].id == .folder(.nzbdav, "job:1", path: "Extras"))
        #expect(top[0].size == 31)

        let extras = try await browser.children(of: top[0].id)
        #expect(extras.map(\.name) == ["Deep", "Making of.mkv"])
        #expect(extras.allSatisfy { $0.parent == top[0].id })

        let file = try await browser.node(.file(.nzbdav, "job:1", "/c/Show S01/Extras/Deep/x.srt"))
        #expect(file.name == "x.srt")
        #expect(file.parent == .folder(.nzbdav, "job:1", path: "Extras/Deep"))
        #expect(file.isDeletable)
        if case .item = file.id { Issue.record("a file is not an item") }

        let deep = try await browser.node(.folder(.nzbdav, "job:1", path: "Extras/Deep"))
        #expect(deep.parent == top[0].id)
    }

    @Test func detailUsesTheListWhenItCarriesFilesAndCachesCalls() async throws {
        let rdList = LibraryItem(id: "torrent:9", backend: .realDebrid, name: "Film", status: .ready)
        let rdDetail = LibraryItem(
            id: "torrent:9", backend: .realDebrid, name: "Film", status: .ready,
            files: [LibraryFile(id: "1", name: "Film.mkv", size: 5)]
        )
        let backend = BrowseBackend(id: .realDebrid, list: [rdList], detailed: [rdDetail])
        let browser = LibraryBrowser(backends: [backend])

        _ = try await browser.children(of: .backend(.realDebrid))
        _ = try await browser.children(of: .item(.realDebrid, "torrent:9"))
        _ = try await browser.node(.file(.realDebrid, "torrent:9", "1"))
        _ = try await browser.node(.item(.realDebrid, "torrent:9"))
        #expect(await backend.listCalls == 1)
        #expect(await backend.detailCalls == 1)

        let torBox = BrowseBackend(id: .torBox, list: [
            LibraryItem(id: "torrent:1", backend: .torBox, name: "A", status: .ready, files: [LibraryFile(id: "0", name: "a.mkv")]),
        ])
        let withFiles = LibraryBrowser(backends: [torBox])
        _ = try await withFiles.children(of: .backend(.torBox))
        #expect(try await withFiles.children(of: .item(.torBox, "torrent:1")).map(\.name) == ["a.mkv"])
        #expect(await torBox.detailCalls == 0)
    }

    @Test func deleteOnlyRemovesWholeItems() async throws {
        let backend = BrowseBackend(id: .nzbdav, list: [pack])
        let browser = LibraryBrowser(backends: [backend])
        await #expect(throws: BackendError.self) {
            try await browser.delete(.file(.nzbdav, "job:1", "/c/Show S01/E01.mkv"))
        }
        try await browser.delete(.item(.nzbdav, "job:1"))
        #expect(await backend.deleted == ["job:1"])
    }

    @Test func droppedTorrentsAndNZBsBecomeSources() async throws {
        let data = Data("d4:infoe".utf8)
        #expect(LibraryBrowser.source(fileNamed: "a.TORRENT", data: data) == .torrentFile(data: data, filename: "a.TORRENT"))
        #expect(LibraryBrowser.source(fileNamed: "b.nzb", data: data) == .nzbFile(data: data, filename: "b.nzb"))
        #expect(LibraryBrowser.source(fileNamed: "c.mkv", data: data) == nil)

        let browser = LibraryBrowser(backends: [BrowseBackend(id: .torBox, list: [])])
        try await browser.add(.torrentFile(data: data, filename: "a.torrent"), to: .torBox)
        await #expect(throws: BackendError.unsupportedSource(.nzb)) {
            try await browser.add(.nzbFile(data: data, filename: "b.nzb"), to: .torBox)
        }
    }

    @Test func downloadRequestAsksTheService() async throws {
        let browser = LibraryBrowser(backends: [BrowseBackend(id: .nzbdav, list: [pack])])
        let request = try await browser.downloadRequest(for: .file(.nzbdav, "job:1", "E"))
        #expect(request.url?.absoluteString == "https://example.org/job:1/E")
    }
}

struct LibrarySnapshotTests {
    @Test func reportsUpdatesAndDeletionsButKeepsFailedServices() async throws {
        let torBox = BrowseBackend(id: .torBox, list: [
            LibraryItem(id: "torrent:1", backend: .torBox, name: "A", status: .ready),
            LibraryItem(id: "torrent:2", backend: .torBox, name: "B", status: .ready),
        ])
        let rd = BrowseBackend(id: .realDebrid, list: [
            LibraryItem(id: "torrent:7", backend: .realDebrid, name: "R", status: .ready),
        ])
        let browser = LibraryBrowser(backends: [torBox, rd], cacheLifetime: 0)

        let first = await browser.topLevel()
        let start = LibrarySnapshot().changes(to: first.nodes, failed: first.failed)
        #expect(start.updated.count == 5)
        #expect(start.snapshot.generation == 1)

        let unchanged = start.snapshot.changes(to: first.nodes)
        #expect(unchanged.updated.isEmpty && unchanged.deleted.isEmpty)
        #expect(unchanged.snapshot.generation == 1)

        await torBox.setList([
            LibraryItem(id: "torrent:1", backend: .torBox, name: "A renamed", status: .ready),
            LibraryItem(id: "torrent:3", backend: .torBox, name: "C", status: .ready),
        ])
        await rd.setFailing(true)
        let second = await browser.topLevel()
        #expect(second.failed == [.realDebrid])

        let changes = start.snapshot.changes(to: second.nodes, failed: second.failed)
        #expect(Set(changes.updated.map(\.name)) == ["A renamed", "C"])
        #expect(changes.deleted == [.item(.torBox, "torrent:2")])
        #expect(changes.snapshot.entries[LibraryNodeID.item(.realDebrid, "torrent:7").rawValue] != nil)
        #expect(changes.snapshot.generation == 2)
    }

    @Test func savesAndLoads() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "s.json")
        let snapshot = LibrarySnapshot(generation: 3, entries: ["b/torBox": "x"])
        try snapshot.save(to: url)
        #expect(LibrarySnapshot.load(from: url) == snapshot)
    }
}
