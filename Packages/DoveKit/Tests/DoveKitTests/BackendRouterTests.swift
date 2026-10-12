import Foundation
import Testing
@testable import DoveKit

private struct FakeBackend: LibraryBackend {
    let id: BackendID
    let supportedSources: Set<SourceKind>
    func validateCredentials() async throws {}
    func add(_ source: Source) async throws -> LibraryItem.ID { "x" }
    func items() async throws -> [LibraryItem] { [] }
    func delete(_ itemID: LibraryItem.ID) async throws {}
    func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest {
        URLRequest(url: URL(string: "https://example.org")!)
    }
}

struct BackendRouterTests {
    private let backends: [any LibraryBackend] = [
        FakeBackend(id: .realDebrid, supportedSources: [.torrent, .hoster]),
        FakeBackend(id: .torBox, supportedSources: [.torrent, .hoster]),
        FakeBackend(id: .nzbdav, supportedSources: [.nzb])
    ]

    @Test func nzbGoesToUsenetBackend() throws {
        let router = BackendRouter(backends: backends, preferred: [.torrent: .torBox])
        #expect(try router.backend(for: .nzbURL(URL(string: "https://x.example/a.nzb")!)).id == .nzbdav)
    }

    @Test func preferenceWinsWithinFamily() throws {
        let router = BackendRouter(backends: backends, preferred: [.torrent: .torBox])
        #expect(try router.backend(for: .magnet("magnet:?xt=urn:btih:abc")).id == .torBox)
    }

    @Test func fallsBackToFirstCompatible() throws {
        let router = BackendRouter(backends: backends)
        #expect(try router.backend(for: .magnet("magnet:?xt=urn:btih:abc")).id == .realDebrid)
    }

    @Test func throwsWhenNothingFits() {
        let router = BackendRouter(backends: [FakeBackend(id: .nzbdav, supportedSources: [.nzb])])
        #expect(throws: BackendError.unsupportedSource(.torrent)) {
            try router.backend(for: .magnet("magnet:?xt=urn:btih:abc"))
        }
    }
}
