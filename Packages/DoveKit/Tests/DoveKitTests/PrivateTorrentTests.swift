import Foundation
import Testing
@testable import DoveKit

enum TorrentFixture {
    /// A minimal single-file torrent; `private` goes in the `info` dictionary like real ones.
    static func torrent(private flag: Int?, privateOutsideInfo: Bool = false) -> Data {
        func string(_ text: String) -> String { "\(text.utf8.count):\(text)" }
        var info = "d" + string("length") + "i1024e" + string("name") + string("file.mkv")
            + string("piece length") + "i16384e" + string("pieces") + string(String(repeating: "x", count: 20))
        if let flag { info += string("private") + "i\(flag)e" }
        info += "e"
        var top = "d" + string("announce") + string("https://tracker.example/abc/announce")
            + string("announce-list") + "ll" + string("https://tracker.example/abc/announce") + "ee"
            + string("info") + info
        if privateOutsideInfo { top += string("private") + "i1e" }
        top += "e"
        return Data(top.utf8)
    }

    static let privateTorrent = torrent(private: 1)
    static let publicTorrent = torrent(private: nil)
}

private struct FakeBackend: LibraryBackend {
    let id: BackendID
    let supportedSources: Set<SourceKind> = [.torrent, .hoster]
    var seedsTorrents = false
    func validateCredentials() async throws {}
    func add(_ source: Source) async throws -> LibraryItem.ID {
        try refusePrivateTorrent(source)
        return "\(id.rawValue):1"
    }
    func items() async throws -> [LibraryItem] { [] }
    func delete(_ itemID: LibraryItem.ID) async throws {}
    func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest {
        URLRequest(url: URL(string: "https://example.org")!)
    }
}

struct PrivateTorrentTests {
    @Test func privateFlagIsReadFromTheInfoDictionary() {
        #expect(TorrentFile.isPrivate(TorrentFixture.privateTorrent))
        #expect(!TorrentFile.isPrivate(TorrentFixture.publicTorrent))
        #expect(!TorrentFile.isPrivate(TorrentFixture.torrent(private: 0)))
        #expect(!TorrentFile.isPrivate(TorrentFixture.torrent(private: nil, privateOutsideInfo: true)), "only info.private counts")
    }

    @Test func garbageIsNotPrivate() {
        #expect(!TorrentFile.isPrivate(Data("<html>error</html>".utf8)))
        #expect(!TorrentFile.isPrivate(Data("d4:infod7:privatei1".utf8)), "truncated")
        #expect(!TorrentFile.isPrivate(Data()))
    }

    @Test func onlyFilesCanBePrivate() {
        #expect(Source.torrentFile(data: TorrentFixture.privateTorrent, filename: "a.torrent").isPrivateTorrent)
        #expect(!Source.magnet("magnet:?xt=urn:btih:abc").isPrivateTorrent)
    }

    private let backends: [any LibraryBackend] = [
        FakeBackend(id: .realDebrid),
        FakeBackend(id: .torBox),
        FakeBackend(id: .debridLink, seedsTorrents: true)
    ]

    @Test func privateTorrentsGoOnlyToSeedingServices() async throws {
        let router = BackendRouter(backends: backends, order: [.realDebrid, .torBox, .debridLink])
        let source = Source.torrentFile(data: TorrentFixture.privateTorrent, filename: "a.torrent")

        #expect(router.candidates(for: source).map(\.id) == [.debridLink])
        let result = try await router.add(source)
        #expect(result.backend == .debridLink && result.skipped.isEmpty, "no other service even sees it")
    }

    @Test func publicTorrentsFollowThePriority() {
        let router = BackendRouter(backends: backends, order: [.realDebrid, .torBox, .debridLink])
        let source = Source.torrentFile(data: TorrentFixture.publicTorrent, filename: "a.torrent")
        #expect(router.candidates(for: source).map(\.id) == [.realDebrid, .torBox, .debridLink])
    }

    @Test func withoutASeedingServiceThePrivateTorrentIsRefused() async {
        let router = BackendRouter(backends: Array(backends.prefix(2)))
        let source = Source.torrentFile(data: TorrentFixture.privateTorrent, filename: "a.torrent")
        await #expect(throws: BackendError.privateTorrent) { try await router.add(source) }
    }

    @Test func nonSeedingAdaptersRefuseItWhenPickedByHand() async {
        // Files drops, Move to and a service picked in the add sheet call the backend directly.
        let source = Source.torrentFile(data: TorrentFixture.privateTorrent, filename: "a.torrent")
        let transport = MockTransport()
        let adapters: [any LibraryBackend] = [
            RealDebridBackend(apiKey: "k", transport: transport),
            TorBoxBackend(apiKey: "k", transport: transport),
            OffcloudBackend(apiKey: "k", transport: transport)
        ]
        for adapter in adapters {
            await #expect(throws: BackendError.privateTorrent) { try await adapter.add(source) }
        }
        #expect(await transport.requests.isEmpty)
    }
}

struct PrivateTrackerRoutingTests {
    @Test func magnetsFromPrivateTrackersGoOnlyToSeedingServices() async throws {
        let backends: [any LibraryBackend] = [
            RealDebridBackend(apiKey: "k", transport: MockTransport()),
            DebridLinkBackend(apiKey: "k", transport: MockTransport())
        ]
        let magnet = Source.magnet("magnet:?xt=urn:btih:" + String(repeating: "a", count: 40))
        let router = BackendRouter(backends: backends, order: [.realDebrid, .debridLink])

        #expect(router.candidates(for: magnet).map(\.id) == [.realDebrid, .debridLink])
        #expect(router.forPrivateTracker(true).candidates(for: magnet).map(\.id) == [.debridLink])
        #expect(router.forPrivateTracker(false).candidates(for: magnet).map(\.id) == [.realDebrid, .debridLink])

        let withoutSeeding = BackendRouter(backends: Array(backends.prefix(1))).forPrivateTracker(true)
        await #expect(throws: BackendError.privateTorrent) { try await withoutSeeding.add(magnet) }
    }
}
