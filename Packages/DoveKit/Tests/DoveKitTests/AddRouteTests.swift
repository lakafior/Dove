import Foundation
import Testing
@testable import DoveKit

private struct StubBackend: LibraryBackend {
    let id: BackendID
    var supportedSources: Set<SourceKind> = [.torrent]
    var takesPrivateTorrents = false
    func validateCredentials() async throws {}
    func add(_ source: Source) async throws -> LibraryItem.ID { "\(id.rawValue):1" }
    func items() async throws -> [LibraryItem] { [] }
    func delete(_ itemID: LibraryItem.ID) async throws {}
    func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest {
        URLRequest(url: URL(string: "https://example.org")!)
    }
}

struct AddRouteTests {
    private let hash = String(repeating: "a", count: 40)
    private let torrentURL = URL(string: "http://192.168.1.10:9117/dl/tl/?passkey=x")!
    private let router = BackendRouter(
        backends: [
            StubBackend(id: .realDebrid),
            StubBackend(id: .torBox),
            StubBackend(id: .debridLink, takesPrivateTorrents: true),
            StubBackend(id: .nzbdav, supportedSources: [.nzb]),
        ],
        order: [.realDebrid, .torBox, .debridLink]
    )

    private func privateGroup(cachedOn service: String?) -> StreamGroup {
        StreamGroup.group([
            StreamCandidate(
                id: "newznab:jackett:1", kind: .p2p, title: "Show.S02.2160p.WEB-DL-GRP", infoHash: hash,
                service: service, cached: service.map { _ in true }, torrentURL: torrentURL, isPrivate: true
            )
        ])[0]
    }

    @Test func usenetAndTorrentsOfTheSameNameStayApart() {
        let groups = StreamGroup.group([
            StreamCandidate(id: "newznab:geek:1", kind: .usenet, title: "Show.S02.2160p.WEB-DL-GRP", nzbURL: URL(string: "https://i.example/1")!),
            StreamCandidate(id: "newznab:jackett:2", kind: .p2p, title: "Show.S02.2160p.WEB-DL-GRP", torrentURL: torrentURL, isPrivate: true),
            StreamCandidate(id: "newznab:finder:3", kind: .usenet, title: "Show.S02.2160p.WEB-DL-GRP", nzbURL: URL(string: "https://i.example/3")!),
        ])
        #expect(groups.count == 2)
        #expect(groups[0].sourceType == .usenet && groups[0].isPrivate == nil && groups[0].candidates.count == 2)
        #expect(groups[1].sourceType == .torrent && groups[1].isPrivate == true)
    }

    @Test func cachedPrivateReleasesGoAsAMagnetToTheCachedService() throws {
        let route = try #require(privateGroup(cachedOn: "torbox").route(through: router))
        #expect(route.source == .magnet(infoHash: hash, name: "Show.S02.2160p.WEB-DL-GRP"))
        #expect(!route.privateTracker)
        #expect(route.router.candidates(for: route.source).map(\.id) == [.torBox])
    }

    @Test func uncachedPrivateReleasesGoAsTheTorrentToSeedingServices() throws {
        let route = try #require(privateGroup(cachedOn: nil).route(through: router))
        #expect(route.source == .torrentURL(torrentURL))
        #expect(route.privateTracker)
        #expect(route.router.candidates(for: route.source).map(\.id) == [.debridLink])
    }

    @Test func aCacheOnAServiceTheUserLacksDoesNotCount() throws {
        let route = try #require(privateGroup(cachedOn: "premiumize").route(through: router))
        #expect(route.privateTracker)
        #expect(route.router.candidates(for: route.source).map(\.id) == [.debridLink])
    }

    @Test func byHandTheCachedServiceAndTheSeedboxAreBothOffered() throws {
        let group = privateGroup(cachedOn: "torbox")
        #expect(group.addTargets(through: router) == [.torBox, .debridLink])
        let torBox = try #require(group.route(to: .torBox, through: router))
        #expect(torBox.source == .magnet(infoHash: hash, name: "Show.S02.2160p.WEB-DL-GRP") && !torBox.privateTracker)
        let seedbox = try #require(group.route(to: .debridLink, through: router))
        #expect(seedbox.source == .torrentURL(torrentURL) && seedbox.privateTracker)
    }

    @Test func publicReleasesAreUnchanged() throws {
        let group = StreamGroup.group([
            StreamCandidate(id: "x", kind: .p2p, title: "Movie", infoHash: hash, service: "torbox", cached: true, isPrivate: false)
        ])[0]
        let route = try #require(group.route(through: router))
        #expect(route.source == .magnet(infoHash: hash, name: "Movie") && !route.privateTracker)
        #expect(route.router.candidates(for: route.source).map(\.id) == [.realDebrid, .torBox, .debridLink])
    }
}
