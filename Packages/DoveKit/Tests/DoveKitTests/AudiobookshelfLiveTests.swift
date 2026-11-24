import Foundation
import Testing
@testable import DoveKit

/// Against a real Audiobookshelf server, only when asked: `DOVE_ABS_LIVE_URL`, `DOVE_ABS_LIVE_KEY` (a user who may
/// upload and download), `DOVE_ABS_LIVE_FILES` (a folder of audio files to send) and optionally
/// `DOVE_ABS_LIVE_READER_KEY` (a user who may not upload). It writes to the server: point it at a throwaway one.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DOVE_ABS_LIVE_URL"] != nil), .serialized)
struct AudiobookshelfLiveTests {
    private let env = ProcessInfo.processInfo.environment
    private var backend: AudiobookshelfBackend {
        AudiobookshelfBackend(baseURL: URL(string: env["DOVE_ABS_LIVE_URL"]!)!, token: env["DOVE_ABS_LIVE_KEY"]!)
    }

    @Test func sendsListsAndDownloads() async throws {
        let account = try await backend.account()
        #expect(account.canUpload)
        #expect(account.canDownload)
        try await backend.validateCredentials()

        let folder = URL(filePath: env["DOVE_ABS_LIVE_FILES"]!)
        let files = try FileManager.default.subpathsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".m4a") || $0.hasSuffix(".jpg") }.sorted().map { folder.appending(path: $0) }
        let title = "Dove Live \(Int(Date.now.timeIntervalSince1970))"
        let progress = ProgressBox()
        try await backend.upload(files: files, title: title, author: "Dove Tester") { progress.last = $0 }
        #expect(progress.last == 1)

        // The server scans the new folder after the upload.
        var found: LibraryItem?
        for _ in 0..<30 where found == nil {
            try await Task.sleep(for: .seconds(1))
            found = try await backend.items().first { $0.book?.title == title }
        }
        let listed = try #require(found)
        #expect(listed.backend == .audiobookshelf)
        #expect(listed.kindHint == .audiobooks)
        #expect(listed.book?.authors == ["Dove Tester"])

        // A cover image sent along becomes the book's cover.
        if files.contains(where: { $0.pathExtension == "jpg" }) {
            let cover = try #require(listed.book?.cover)
            let (image, answer) = try await URLSession.shared.data(for: try await backend.coverRequest(for: cover))
            #expect((answer as? HTTPURLResponse)?.statusCode == 200)
            #expect(image.starts(with: [0xFF, 0xD8]))
        }

        let item = try await backend.item(listed.id)
        #expect(Set(item.files.map { ($0.name as NSString).lastPathComponent }).isSuperset(of: ["CD1 - 01.m4a", "CD2 - 01.m4a"]))
        let file = try #require(item.files.first { $0.name.hasSuffix("CD1 - 01.m4a") })
        let (data, response) = try await URLSession.shared.data(for: try await backend.downloadRequest(itemID: item.id, fileID: file.id))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data == (try Data(contentsOf: folder.appending(path: "CD1/01.m4a"))))

        // The same book again: the folder is taken, and Dove says so before sending.
        await #expect(throws: BackendError.api(message: "Audiobookshelf already has a folder for \(title). Remove or rename it there to send it again.")) {
            try await backend.upload(files: files, title: title, author: "Dove Tester")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DOVE_ABS_LIVE_READER_KEY"] != nil))
    func refusesAnAccountWithoutUpload() async throws {
        let reader = AudiobookshelfBackend(baseURL: URL(string: env["DOVE_ABS_LIVE_URL"]!)!, token: env["DOVE_ABS_LIVE_READER_KEY"]!)
        #expect(try await reader.account().canUpload == false)
        await #expect(throws: BackendError.self) { try await reader.uploadTarget() }
        let wrong = AudiobookshelfBackend(baseURL: URL(string: env["DOVE_ABS_LIVE_URL"]!)!, token: "not-a-key")
        await #expect(throws: BackendError.api(message: "Audiobookshelf refused the API key. Make a new one in Audiobookshelf › Settings › API Keys.")) {
            try await wrong.validateCredentials()
        }
    }
}

private final class ProgressBox: @unchecked Sendable {
    var last: Double = 0
}
