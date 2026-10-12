import Foundation
import Testing
@testable import DoveKit

struct UsenetPlaybackTests {
    private let source = Source.nzbURL(URL(string: "https://indexer.example/get/1")!)

    private func job(_ status: LibraryItem.Status, files: [LibraryFile] = []) -> LibraryItem {
        LibraryItem(id: "nzo:1", backend: .nzbdav, name: "Movie.2024.2160p", status: status, files: files)
    }

    private let files = [
        LibraryFile(id: "/content/movies/Movie/Sample/sample.mkv", name: "Sample/sample.mkv", size: 50),
        LibraryFile(id: "/content/movies/Movie/movie.mkv", name: "movie.mkv", size: 5_000),
        LibraryFile(id: "/content/movies/Movie/movie.nfo", name: "movie.nfo", size: 10_000),
    ]

    @Test func waitsForTheJobThenReturnsTheMainVideo() async throws {
        let backend = JobBackend(.nzbdav, item: job(.downloading(progress: 0)))
        await backend.setLink(URL(string: "https://nzb.example/content/movies/Movie/movie.mkv")!, for: files[1].id)
        let ready = job(.ready, files: files)
        Task {
            try await Task.sleep(for: .milliseconds(30))
            await backend.set(ready)
        }

        let prepared = try await UsenetPlayback.prepare(source, on: backend, interval: .milliseconds(5))

        #expect(prepared.itemID == "nzo:1")
        #expect(prepared.url.absoluteString == "https://nzb.example/content/movies/Movie/movie.mkv")
        #expect(await backend.added == 1)
    }

    @Test func aKnownJobIsNotAddedAgain() async throws {
        let backend = JobBackend(.nzbdav, item: job(.ready, files: files))
        await backend.setLink(URL(string: "https://nzb.example/x.mkv")!, for: files[1].id)

        _ = try await UsenetPlayback.prepare(source, itemID: "nzo:1", on: backend)

        #expect(await backend.added == 0)
    }

    @Test func missingArticlesFailWithTheReason() async {
        let backend = JobBackend(.nzbdav, item: job(.failed(reason: "Article with message-id abc not found.")))
        await #expect(throws: BackendError.api(message: "nzbdav could not get this release: Article with message-id abc not found. Try another one.")) {
            try await UsenetPlayback.prepare(source, on: backend, interval: .milliseconds(1))
        }
    }

    @Test func givesUpAfterTheTimeout() async {
        let backend = JobBackend(.nzbdav, item: job(.queued))
        await #expect(throws: BackendError.self) {
            try await UsenetPlayback.prepare(source, on: backend, timeout: .milliseconds(20), interval: .milliseconds(5))
        }
    }
}
