import Foundation
import Testing
@testable import DoveKit

/// Records adds and deletes; `sameIDOnAdd` answers like a service that keeps one item per hash.
private actor ActionBackendLog {
    var calls: [String] = []
    func record(_ call: String) { calls.append(call) }
}

private struct ActionBackend: LibraryBackend {
    let id: BackendID
    let log: ActionBackendLog
    var newID = "torrent:2"
    var addFails = false
    var deleteFails = false
    let supportedSources: Set<SourceKind> = [.torrent, .hoster]

    func validateCredentials() async throws {}
    func add(_ source: Source) async throws -> LibraryItem.ID {
        guard case .magnet(let magnet) = source else { throw BackendError.invalidResponse }
        await log.record("add \(id.rawValue) \(InfoHash.fromMagnet(magnet) ?? "?")")
        if addFails { throw BackendError.api(message: "nope") }
        return newID
    }
    func items() async throws -> [LibraryItem] { [] }
    func delete(_ itemID: LibraryItem.ID) async throws {
        await log.record("delete \(id.rawValue) \(itemID)")
        if deleteFails { throw BackendError.api(message: "busy") }
    }
    func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest {
        URLRequest(url: URL(string: "https://example.org")!)
    }
}

/// nzbdav-like: hands back the stored NZB, takes NZBs.
private struct NZBBackend: NZBProviding {
    let id: BackendID
    let log: ActionBackendLog
    var newID = "nzo:new"
    let supportedSources: Set<SourceKind> = [.nzb]

    /// The server-side retry's answer; nil like an older nzbdav.
    var retried: LibraryItem.ID?

    func providesNZB(for item: LibraryItem) -> Bool { item.nzbBlobID != nil }
    func retry(_ item: LibraryItem) async throws -> LibraryItem.ID? {
        await log.record("retry \(id.rawValue) \(item.id)")
        return retried
    }
    func nzb(of item: LibraryItem) async throws -> Source {
        await log.record("fetch \(id.rawValue) \(item.nzbBlobID ?? "?")")
        return .nzbFile(data: Data("<nzb/>".utf8), filename: "\(item.name).nzb")
    }
    func validateCredentials() async throws {}
    func add(_ source: Source) async throws -> LibraryItem.ID {
        guard case .nzbFile(_, let name) = source else { throw BackendError.invalidResponse }
        await log.record("add \(id.rawValue) \(name)")
        return newID
    }
    func items() async throws -> [LibraryItem] { [] }
    func delete(_ itemID: LibraryItem.ID) async throws { await log.record("delete \(id.rawValue) \(itemID)") }
    func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest {
        URLRequest(url: URL(string: "https://example.org")!)
    }
}

struct LibraryActionsTests {
    private let hash = String(repeating: "a", count: 40)
    private var item: LibraryItem {
        LibraryItem(id: "torrent:1", backend: .realDebrid, name: "Dune Part Two 2024", status: .failed(reason: "dead"), infoHash: hash.uppercased())
    }

    @Test func magnetCarriesTheHashAndTheName() {
        #expect(item.infoHash == hash)
        #expect(item.magnet == "magnet:?xt=urn:btih:\(hash)&dn=Dune%20Part%20Two%202024")
        #expect(LibraryItem(id: "x", backend: .torBox, name: "x", status: .ready, infoHash: "not a hash").magnet == nil)
        #expect(InfoHash.fromMagnet("magnet:?xt=urn:btih:\(hash.uppercased())&dn=x") == hash)
        #expect(InfoHash.fromMagnet("https://example.org/?xt=urn:btih:\(hash)") == nil)
    }

    @Test func reinsertAddsThenDeletesTheOldItem() async throws {
        let log = ActionBackendLog()
        let result = try await LibraryActions.reinsert(item, on: ActionBackend(id: .realDebrid, log: log))
        #expect(result == .init(backend: .realDebrid, itemID: "torrent:2", deletedOriginal: true))
        #expect(await log.calls == ["add realDebrid \(hash)", "delete realDebrid torrent:1"])
    }

    @Test func serviceWithOneItemPerHashGetsDeleteThenAdd() async throws {
        let log = ActionBackendLog()
        let backend = ActionBackend(id: .torBox, log: log, newID: "torrent:1")
        let result = try await LibraryActions.reinsert(item, on: backend)
        #expect(result.itemID == "torrent:1")
        #expect(await log.calls == ["add torBox \(hash)", "delete torBox torrent:1", "add torBox \(hash)"])
    }

    @Test func failedReinsertKeepsTheOldItem() async {
        let log = ActionBackendLog()
        await #expect(throws: BackendError.self) {
            try await LibraryActions.reinsert(item, on: ActionBackend(id: .realDebrid, log: log, addFails: true))
        }
        #expect(await log.calls == ["add realDebrid \(hash)"])
    }

    @Test func moveDeletesOnlyWhenAskedAndAfterTheAdd() async throws {
        let log = ActionBackendLog()
        let rd = ActionBackend(id: .realDebrid, log: log)
        let torBox = ActionBackend(id: .torBox, log: log, newID: "torrent:9")

        let kept = try await LibraryActions.move(item, from: rd, to: torBox, deleteOriginal: false)
        #expect(kept == .init(backend: .torBox, itemID: "torrent:9", deletedOriginal: false))
        let moved = try await LibraryActions.move(item, from: rd, to: torBox, deleteOriginal: true)
        #expect(moved.deletedOriginal)
        #expect(await log.calls == ["add torBox \(hash)", "add torBox \(hash)", "delete realDebrid torrent:1"])

        let failing = ActionBackend(id: .offcloud, log: log, addFails: true)
        await #expect(throws: BackendError.self) {
            try await LibraryActions.move(item, from: rd, to: failing, deleteOriginal: true)
        }
        #expect(await log.calls.last == "add offcloud \(hash)")
    }

    @Test func itemWithoutHashCannotBeReinserted() async {
        let hoster = LibraryItem(id: "download:1", backend: .realDebrid, name: "file.rar", status: .ready)
        await #expect(throws: BackendError.self) {
            try await LibraryActions.reinsert(hoster, on: ActionBackend(id: .realDebrid, log: ActionBackendLog()))
        }
    }

    private let failedJob = LibraryItem(id: "nzo:old", backend: .nzbdav, name: "Show.S01E01", status: .failed(reason: "missing articles"), nzbBlobID: "blob-1")

    @Test func nzbReinsertFetchesDeletesThenAdds() async throws {
        let log = ActionBackendLog()
        let nzbdav = NZBBackend(id: .nzbdav, log: log)
        #expect(LibraryActions.canReAdd(failedJob, on: nzbdav))
        #expect(LibraryActions.sourceKind(of: failedJob) == .nzb)

        let result = try await LibraryActions.reinsert(failedJob, on: nzbdav)

        #expect(result.itemID == "nzo:new")
        #expect(await log.calls == ["retry nzbdav nzo:old", "fetch nzbdav blob-1", "delete nzbdav nzo:old", "add nzbdav Show.S01E01.nzb"])
    }

    @Test func nzbMovesToAnotherUsenetService() async throws {
        let log = ActionBackendLog()
        let nzbdav = NZBBackend(id: .nzbdav, log: log)
        let torBox = NZBBackend(id: .torBox, log: log, newID: "usenet:5")

        let result = try await LibraryActions.move(failedJob, from: nzbdav, to: torBox, deleteOriginal: true)

        #expect(result == .init(backend: .torBox, itemID: "usenet:5", deletedOriginal: true))
        #expect(await log.calls == ["fetch nzbdav blob-1", "add torBox Show.S01E01.nzb", "delete nzbdav nzo:old"])
        // A debrid without Usenet cannot take it.
        await #expect(throws: BackendError.unsupportedSource(.nzb)) {
            try await LibraryActions.move(failedJob, from: nzbdav, to: ActionBackend(id: .realDebrid, log: log), deleteOriginal: false)
        }
    }

    @Test func nzbWithoutAProviderCannotBeReAdded() {
        #expect(!LibraryActions.canReAdd(failedJob, on: ActionBackend(id: .torBox, log: ActionBackendLog())))
        #expect(!LibraryActions.canReAdd(failedJob, on: nil))
    }

    @Test func failedJobIsRetriedByTheServerWhenItCan() async throws {
        let log = ActionBackendLog()
        let infiniDysk = NZBBackend(id: .nzbdav, log: log, retried: "nzo:retried")

        let result = try await LibraryActions.reinsert(failedJob, on: infiniDysk)

        #expect(result == .init(backend: .nzbdav, itemID: "nzo:retried", deletedOriginal: true))
        #expect(await log.calls == ["retry nzbdav nzo:old", "delete nzbdav nzo:old"])

        // A finished job is not "retried": it is added again from its NZB.
        let finished = LibraryItem(id: "nzo:done", backend: .nzbdav, name: "Done", status: .ready, nzbBlobID: "blob-2")
        _ = try await LibraryActions.reinsert(finished, on: infiniDysk)
        #expect(await log.calls.suffix(3) == ["fetch nzbdav blob-2", "delete nzbdav nzo:done", "add nzbdav Done.nzb"])
    }
}
