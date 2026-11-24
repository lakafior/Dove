import DoveKit
import Foundation

extension AppModel {
    /// Where "Send to Audiobookshelf" is in its work.
    public enum ShelfSendStep: Sendable, Equatable {
        /// Fetching the release's files from the service to this device (fraction of the bytes).
        case fetching(Double)
        /// Sending them to the server.
        case sending(Double)
    }

    /// Sends an audiobook release to Audiobookshelf: its audio files (and cover image, when it has one) come to
    /// this device (from Downloads when they are already there), then go to the server in one upload, filed by the
    /// server under Author/Title. Audiobookshelf cannot fetch links itself, so the files pass through the device;
    /// the temporary copies are removed afterwards.
    public func sendToAudiobookshelf(
        _ item: LibraryItem,
        title: String,
        author: String?,
        progress: @escaping @MainActor (ShelfSendStep) -> Void
    ) async throws {
        guard let shelf = backend(.audiobookshelf) as? AudiobookshelfBackend else {
            throw BackendError.api(message: "Set up Audiobookshelf in Settings › Your libraries first.")
        }
        guard let source = backend(item.backend) else {
            throw BackendError.api(message: "\(item.backend.displayName) is no longer configured.")
        }
        // Checked before gigabytes come down: the account may upload, the folder is free.
        let target = try await shelf.uploadTarget()
        if try await shelf.pathExists(title: title, author: author, series: nil, folder: target.folder).exists {
            throw BackendError.api(message: "Audiobookshelf already has a folder for \(title). Remove or rename it there to send it again.")
        }

        let release = item.files.isEmpty ? try await source.item(item.id) : item
        let tracks = try AudiobookTracks.tracks(in: release.files).get()
        let audioIDs = Set(tracks.map(\.fileID))
        let cover = release.files.first { file in
            ["jpg", "jpeg", "png"].contains((file.name as NSString).pathExtension.lowercased()) && !FileKind.isSample(file.name)
        }
        let files = release.files.filter { audioIDs.contains($0.id) || $0.id == cover?.id }

        let folder = FileManager.default.temporaryDirectory.appending(path: "abs-send-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let total = max(1, files.compactMap(\.size).reduce(0, +))
        var fetched: Int64 = 0
        var local: [URL] = []
        progress(.fetching(0))
        for file in files {
            try Task.checkCancellation()
            // Folders kept (CD1/01.mp3), so the upload can tell repeated names apart.
            let destination = folder.appending(path: file.name)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let record = downloads.records.first(where: {
                $0.state == .finished && $0.isSameFile(backend: item.backend, itemID: item.id, fileID: file.id)
            }), let existing = downloads.fileURL(for: record) {
                try FileManager.default.copyItem(at: existing, to: destination)
            } else {
                let request = try await source.downloadRequest(itemID: release.id, fileID: file.id)
                let (temporary, response) = try await URLSession.shared.download(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    try? FileManager.default.removeItem(at: temporary)
                    throw BackendError.api(message: "\(item.backend.displayName) answered \(http.statusCode) for \(file.name).")
                }
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            local.append(destination)
            fetched += file.size ?? 0
            progress(.fetching(Double(fetched) / Double(total)))
        }

        progress(.sending(0))
        try await shelf.upload(files: local, title: title, author: author) { fraction in
            Task { @MainActor in progress(.sending(fraction)) }
        }
        await library.refresh(using: self, afterChange: true)
    }
}

extension AppModel {
    /// The book's first ready release elsewhere that has playable audio goes to Audiobookshelf.
    public func sendToAudiobookshelf(_ book: BookTitle, progress: @escaping @MainActor (ShelfSendStep) -> Void) async throws {
        var refusal: String?
        for shelfItem in book.items where shelfItem.item.status == .ready && shelfItem.item.backend != .audiobookshelf {
            var item = shelfItem.item
            if item.files.isEmpty, let source = backend(item.backend) {
                guard let full = try? await source.item(item.id) else { continue }
                item = full
            }
            switch AudiobookTracks.tracks(in: item.files) {
            case .success:
                try await sendToAudiobookshelf(item, title: book.book?.title ?? book.name, author: book.author, progress: progress)
                return
            case .failure(let reason):
                refusal = reason.message
            }
        }
        throw BackendError.api(message: refusal ?? "No release is ready on a service yet.")
    }

    /// Starts sending a book (once: a second call while it runs does nothing); progress and the outcome land in
    /// `shelfSends` and `shelfSendResults`.
    public func startShelfSend(_ book: BookTitle) {
        guard shelfSends[book.id] == nil else { return }
        shelfSends[book.id] = .fetching(0)
        shelfSendResults[book.id] = "Keep Dove open until it finishes: the files pass through this device."
        let id = book.id
        shelfSendTasks[id] = Task {
            defer {
                shelfSends[id] = nil
                shelfSendTasks[id] = nil
            }
            do {
                try await sendToAudiobookshelf(book) { [weak self] step in self?.shelfSends[id] = step }
                shelfSendResults[id] = "Sent. Audiobookshelf files it under Author/Title and scans it in a moment."
            } catch is CancellationError {
                shelfSendResults[id] = "Cancelled."
            } catch let error as URLError where error.code == .cancelled {
                shelfSendResults[id] = "Cancelled."
            } catch {
                shelfSendResults[id] = error.localizedDescription
            }
        }
    }

    public func cancelShelfSend(_ bookID: String) {
        shelfSendTasks[bookID]?.cancel()
    }

    /// Audiobookshelf is set up and does not list this book yet.
    public func canSendToAudiobookshelf(_ book: BookTitle) -> Bool {
        book.format == .audiobook && backend(.audiobookshelf) != nil && !book.backends.contains(.audiobookshelf)
    }
}
