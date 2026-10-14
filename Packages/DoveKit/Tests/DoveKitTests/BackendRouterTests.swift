import Foundation
import Testing
@testable import DoveKit

private struct FakeBackend: LibraryBackend {
    let id: BackendID
    let supportedSources: Set<SourceKind>
    var failure: BackendError?
    func validateCredentials() async throws {}
    func add(_ source: Source) async throws -> LibraryItem.ID {
        if let failure { throw failure }
        return "\(id.rawValue):1"
    }
    func items() async throws -> [LibraryItem] { [] }
    func delete(_ itemID: LibraryItem.ID) async throws {}
    func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest {
        URLRequest(url: URL(string: "https://example.org")!)
    }
}

struct BackendRouterTests {
    private let magnet = Source.magnet("magnet:?xt=urn:btih:abc")
    private let backends: [any LibraryBackend] = [
        FakeBackend(id: .realDebrid, supportedSources: [.torrent, .hoster]),
        FakeBackend(id: .torBox, supportedSources: [.torrent, .hoster]),
        FakeBackend(id: .nzbdav, supportedSources: [.nzb])
    ]

    @Test func nzbGoesToUsenetBackend() throws {
        let router = BackendRouter(backends: backends, order: [.torBox])
        #expect(try router.backend(for: .nzbURL(URL(string: "https://x.example/a.nzb")!)).id == .nzbdav)
    }

    @Test func orderDecidesWithinFamily() throws {
        let router = BackendRouter(backends: backends, order: [.torBox, .realDebrid])
        #expect(router.candidates(for: magnet).map(\.id) == [.torBox, .realDebrid])
    }

    @Test func unlistedBackendsKeepTheirPlaceAfterListedOnes() {
        let all: [any LibraryBackend] = backends + [FakeBackend(id: .offcloud, supportedSources: [.torrent])]
        let router = BackendRouter(backends: all, order: [.offcloud])
        #expect(router.candidates(for: magnet).map(\.id) == [.offcloud, .realDebrid, .torBox])
    }

    @Test func nzbTriesUsenetBackendsBeforeDebridsThatTakeNZBs() {
        let all: [any LibraryBackend] = [
            FakeBackend(id: .torBox, supportedSources: [.torrent, .nzb]),
            FakeBackend(id: .nzbdav, supportedSources: [.nzb]),
        ]
        let router = BackendRouter(backends: all, order: [.torBox, .realDebrid])
        let nzb = Source.nzbURL(URL(string: "https://indexer.example/get/1")!)
        #expect(router.candidates(for: nzb).map(\.id) == [.nzbdav, .torBox])
        #expect(router.candidates(for: magnet).map(\.id) == [.torBox])
    }

    @Test func nzbFollowsTheUsenetOrderWhenOneIsSet() {
        let all: [any LibraryBackend] = [
            FakeBackend(id: .torBox, supportedSources: [.torrent, .nzb]),
            FakeBackend(id: .offcloud, supportedSources: [.torrent, .nzb]),
            FakeBackend(id: .nzbdav, supportedSources: [.nzb]),
        ]
        let router = BackendRouter(backends: all, order: [.torBox, .offcloud], usenetOrder: [.offcloud, .nzbdav, .torBox])
        let nzb = Source.nzbURL(URL(string: "https://indexer.example/get/1")!)
        #expect(router.candidates(for: nzb).map(\.id) == [.offcloud, .nzbdav, .torBox])
        // Torrents keep the debrid order.
        #expect(router.candidates(for: magnet).map(\.id) == [.torBox, .offcloud])
    }

    @Test func throwsWhenNothingFits() {
        let router = BackendRouter(backends: [FakeBackend(id: .nzbdav, supportedSources: [.nzb])])
        #expect(throws: BackendError.unsupportedSource(.torrent)) {
            try router.backend(for: magnet)
        }
    }

    @Test func addFallsThroughToTheNextBackendOnAnyError() async throws {
        let router = BackendRouter(backends: [
            FakeBackend(id: .realDebrid, supportedSources: [.torrent], failure: .api(message: "refused")),
            FakeBackend(id: .offcloud, supportedSources: [.torrent], failure: .unauthorized),
            FakeBackend(id: .torBox, supportedSources: [.torrent])
        ])

        let result = try await router.add(magnet)

        #expect(result.backend == .torBox)
        #expect(result.itemID == "torBox:1")
        #expect(result.skipped.map(\.backend) == [.realDebrid, .offcloud])
    }

    @Test func addReportsEveryFailureWhenAllFail() async {
        let router = BackendRouter(backends: [
            FakeBackend(id: .realDebrid, supportedSources: [.torrent], failure: .api(message: "refused")),
            FakeBackend(id: .torBox, supportedSources: [.torrent], failure: .rateLimited)
        ])
        do {
            _ = try await router.add(magnet)
            Issue.record("expected failure")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("Real-Debrid: refused"))
            #expect(message.contains("TorBox: Too many requests"))
        }
    }
}
