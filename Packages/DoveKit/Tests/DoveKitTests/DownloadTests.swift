import Foundation
import Testing
@testable import DoveKit

struct DownloadNamingTests {
    @Test func sanitizedKeepsTheLastPathComponent() {
        #expect(DownloadNaming.sanitized("Show/Season 1/Show.S01E01.mkv") == "Show.S01E01.mkv")
        #expect(DownloadNaming.sanitized("Movie: Part 2.mkv") == "Movie- Part 2.mkv")
        #expect(DownloadNaming.sanitized("  ") == "download")
        #expect(DownloadNaming.sanitized("..") == "download")
    }

    @Test func uniqueNumbersTakenNames() {
        let taken: Set = ["a.mkv", "a (2).mkv", "notes"]
        #expect(DownloadNaming.unique("b.mkv", isTaken: taken.contains) == "b.mkv")
        #expect(DownloadNaming.unique("a.mkv", isTaken: taken.contains) == "a (3).mkv")
        #expect(DownloadNaming.unique("notes", isTaken: taken.contains) == "notes (2)")
    }

    @Test func progressNeedsAKnownSize() {
        var record = DownloadRecord(backend: .torBox, itemID: "torrent:1", fileID: "1", name: "a", bytesWritten: 50)
        #expect(record.progress == nil)
        record.totalBytes = 200
        #expect(record.progress == 0.25)
    }
}

struct DownloadStoreTests {
    @Test func recordsAndResumeDataRoundTrip() throws {
        let store = DownloadStore(directory: try temporaryDirectory())
        let record = DownloadRecord(
            backend: .realDebrid, itemID: "torrent:A", fileID: "3", name: "e.mkv",
            state: .failed(reason: "Timed out"), bytesWritten: 10, totalBytes: 20
        )

        store.save([record])
        store.setResumeData(Data([1, 2]), for: record.id)

        #expect(store.load() == [record])
        #expect(store.resumeData(for: record.id) == Data([1, 2]))
        store.setResumeData(nil, for: record.id)
        #expect(store.resumeData(for: record.id) == nil)
    }
}

/// Runs real `URLSession` download tasks against `StubProtocol` on an ephemeral session.
@MainActor
@Suite(.serialized)
struct DownloadManagerTests {
    private func makeManager(store: DownloadStore? = nil) throws -> (DownloadManager, URL) {
        let root = try temporaryDirectory()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let files = root.appending(path: "Documents")
        let manager = DownloadManager(
            configuration: configuration,
            directory: files,
            store: store ?? DownloadStore(directory: root.appending(path: "Support"))
        )
        return (manager, files)
    }

    private func url(_ path: String) -> URL { URL(string: "https://dl.test/\(UUID().uuidString)/\(path)")! }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @Test func finishedFileLandsInTheDirectory() async throws {
        let (manager, files) = try makeManager()
        let source = url("e01.mkv")
        StubProtocol.set(source, status: 200, body: Data("video".utf8))

        let id = try manager.start(
            URLRequest(url: source), backend: .torBox, itemID: "torrent:1",
            file: LibraryFile(id: "7", name: "Show/Show.S01E01.mkv", size: 5)
        )
        try await waitUntil { manager[id]?.state == .finished }

        let record = try #require(manager[id])
        #expect(record.localName == "Show.S01E01.mkv")
        let file = try #require(manager.fileURL(for: record))
        #expect(file.deletingLastPathComponent().standardizedFileURL == files.standardizedFileURL)
        #expect(try Data(contentsOf: file) == Data("video".utf8))
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func startingTheSameFileTwiceReusesTheRecord() async throws {
        let (manager, _) = try makeManager()
        let source = url("a.mkv")
        StubProtocol.set(source, status: 200, body: Data("a".utf8))
        let file = LibraryFile(id: "1", name: "a.mkv")

        let first = try manager.start(URLRequest(url: source), backend: .torBox, itemID: "torrent:1", file: file)
        try await waitUntil { manager[first]?.state == .finished }
        let second = try manager.start(URLRequest(url: source), backend: .torBox, itemID: "torrent:1", file: file)

        #expect(first == second)
        #expect(manager.records.count == 1)
    }

    @Test func takenNameGetsANumber() async throws {
        let (manager, _) = try makeManager()
        let source = url("a.mkv")
        StubProtocol.set(source, status: 200, body: Data("a".utf8))

        let first = try manager.start(URLRequest(url: source), backend: .torBox, itemID: "torrent:1", file: LibraryFile(id: "1", name: "a.mkv"))
        try await waitUntil { manager[first]?.state == .finished }
        let second = try manager.start(URLRequest(url: source), backend: .offcloud, itemID: "cloud:2", file: LibraryFile(id: "1", name: "a.mkv"))
        try await waitUntil { manager[second]?.state == .finished }

        #expect(manager[second]?.localName == "a (2).mkv")
    }

    @Test func httpErrorFailsAndRetryAsksForAFreshLink() async throws {
        let (manager, _) = try makeManager()
        let expired = url("expired.mkv")
        let fresh = url("fresh.mkv")
        StubProtocol.set(expired, status: 403, body: Data("<html>".utf8))
        StubProtocol.set(fresh, status: 200, body: Data("ok".utf8))
        var asked: [DownloadRecord.ID] = []
        manager.requestProvider = { record in
            asked.append(record.id)
            return URLRequest(url: fresh)
        }

        let id = try manager.start(URLRequest(url: expired), backend: .realDebrid, itemID: "torrent:A", file: LibraryFile(id: "1", name: "x.mkv"))
        try await waitUntil { if case .failed = manager[id]?.state { true } else { false } }
        #expect(manager[id]?.state == .failed(reason: "The server answered 403. Try again for a fresh link."))

        try await manager.resume(id)
        try await waitUntil { manager[id]?.state == .finished }
        #expect(asked == [id])
    }

    @Test func removeDeletesTheFileAndTheRecord() async throws {
        let (manager, _) = try makeManager()
        let source = url("a.mkv")
        StubProtocol.set(source, status: 200, body: Data("a".utf8))
        let id = try manager.start(URLRequest(url: source), backend: .torBox, itemID: "torrent:1", file: LibraryFile(id: "1", name: "a.mkv"))
        try await waitUntil { manager[id]?.state == .finished }
        let file = try #require(manager[id].flatMap(manager.fileURL))

        manager.remove(id)

        #expect(manager.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func removeCanKeepTheFile() async throws {
        let (manager, _) = try makeManager()
        let source = url("b.mkv")
        StubProtocol.set(source, status: 200, body: Data("b".utf8))
        let id = try manager.start(URLRequest(url: source), backend: .torBox, itemID: "torrent:2", file: LibraryFile(id: "1", name: "b.mkv"))
        try await waitUntil { manager[id]?.state == .finished }
        let file = try #require(manager[id].flatMap(manager.fileURL))

        manager.remove(id, deletingFile: false)

        #expect(manager.records.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func tooBigForTheDiskIsRefusedUpFront() throws {
        let (manager, _) = try makeManager()
        #expect(throws: BackendError.self) {
            try manager.start(
                URLRequest(url: url("huge.mkv")), backend: .torBox, itemID: "torrent:1",
                file: LibraryFile(id: "1", name: "huge.mkv", size: .max / 2)
            )
        }
        #expect(manager.records.isEmpty)
    }

    @Test func downloadsWithoutATaskAfterRelaunchAreSettled() async throws {
        let store = DownloadStore(directory: try temporaryDirectory())
        let resumable = DownloadRecord(backend: .torBox, itemID: "torrent:1", fileID: "1", name: "a.mkv")
        let lost = DownloadRecord(backend: .torBox, itemID: "torrent:1", fileID: "2", name: "b.mkv")
        store.save([resumable, lost])
        store.setResumeData(Data([1]), for: resumable.id)

        let (manager, _) = try makeManager(store: store)
        try await waitUntil { manager[lost.id]?.state != .downloading }

        #expect(manager[resumable.id]?.state == .paused)
        #expect(manager[lost.id]?.state == .failed(reason: "Interrupted."))
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "DoveKitTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Serves canned responses by full URL.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [URL: (Int, Data)] = [:]

    static func set(_ url: URL, status: Int, body: Data) {
        lock.withLock { responses[url] = (status, body) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let (status, body) = Self.lock.withLock({ Self.responses[url] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Length": String(body.count)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
