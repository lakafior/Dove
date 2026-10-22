import DoveKit
import Foundation

// MARK: - Audiobooks

extension AppModel {
    public enum ContinueResult {
        case playing(String)
        case failed(String)
    }

    /// The audiobook listened to last that is still in the library, from its saved place (Siri, Shortcuts, the
    /// app icon's Quick Action). Plays on if it is already loaded.
    public func continueAudiobook() async -> ContinueResult {
        // A book that is loaded; music in the player gives way to the last book.
        if let session = audiobook.session, !session.isMusic {
            if !audiobook.isPlaying { audiobook.play() }
            return .playing(session.title)
        }
        let books = library.books
        guard let book = audiobook.listening().lazy.compactMap({ entry in books.first { $0.guess.key == entry.key } }).first else {
            return .failed("No audiobook to continue. Start one in Dove first.")
        }
        if let refusal = await playAudiobook(book) { return .failed(refusal) }
        return .playing(book.name)
    }

    /// Plays a book from where it was left: the first ready release with playable audio (services that list items
    /// without files are asked for them). Returns why it could not, or nil once the player has it.
    public func playAudiobook(_ book: BookTitle) async -> String? {
        var refusal: String?
        for shelfItem in book.items where shelfItem.item.status == .ready {
            var item = shelfItem.item
            if item.files.isEmpty, let backend = backend(item.backend) {
                do {
                    item = try await backend.item(item.id)
                } catch {
                    refusal = error.localizedDescription
                    continue
                }
            }
            switch AudiobookTracks.tracks(in: item.files) {
            case .success(let tracks):
                audiobook.start(AudiobookPlayer.Session(
                    key: book.guess.key, title: book.name, author: book.author,
                    cover: book.book?.cover, item: item, tracks: tracks
                ))
                audiobook.isPresented = true
                platform.audiobookStarted()
                return nil
            case .failure(let reason):
                refusal = reason.message
            }
        }
        return refusal ?? "No release is ready on a service yet."
    }
}

// MARK: - Watchlist

extension AppModel {
    /// Adds or removes a title, then fetches what the watchlist needs for it (a series' episodes, a movie's dates).
    public func toggleWatchlist(_ media: MediaSummary, otherIDs: [String] = []) {
        watchlist.toggle(media, otherIDs: otherIDs)
        platform.libraryUpdated(self)
        guard watchlist.contains(media) else { return }
        Task {
            await review.run(using: self)
            await watchlist.refresh(using: self)
        }
    }
}

// MARK: - iCloud Drive

extension AppModel {
    /// "On", "Not available" or "Checking…".
    public var iCloudState: String {
        if iCloudFolder != nil { return "On" }
        return iCloudChecked ? "Not available" : "Checking…"
    }
}

// MARK: - Whole items

extension AppModel {
    /// Downloads every file of a ready library item to the place its kind goes (Settings › Save to; iCloud Drive
    /// keeps its own layout): one file on its own, several in a folder named after the item. Services that list
    /// items without files are asked for them first. Returns how many files started.
    @discardableResult
    public func downloadItem(_ shelf: ShelfItem) async throws -> Int {
        var item = shelf.item
        // iCloud Drive's files are on this device already: there is nothing to fetch (and URLSession refuses file URLs).
        guard !item.backend.isOnDevice else {
            throw BackendError.api(message: "\(shelf.name) is already on this device, in \(item.backend.displayName).")
        }
        guard case .ready = item.status else {
            throw BackendError.api(message: "\(shelf.name) is not ready on \(item.backend.displayName) yet.")
        }
        guard let backend = backend(item.backend) else {
            throw BackendError.api(message: "\(item.backend.displayName) is no longer configured.")
        }
        if item.files.isEmpty { item = try await backend.item(item.id) }
        guard !item.files.isEmpty else {
            throw BackendError.api(message: "\(item.backend.displayName) lists no files for \(shelf.name).")
        }
        let destination: DownloadDestination = if case .download(let chosen) = place(for: shelf.kind), isAvailable(.download(chosen)) {
            chosen
        } else {
            .device
        }
        for file in item.files {
            if destination == .iCloud {
                try await download(file, of: item, to: .iCloud)
                continue
            }
            let request = try await backend.downloadRequest(itemID: item.id, fileID: file.id)
            let placement = item.files.count > 1
                ? LibraryFolderLayout.Placement(folder: LibraryFolderLayout.component(shelf.name), fileName: LibraryFolderLayout.cleanPath(file.name))
                : nil
            try downloads.start(request, backend: item.backend, itemID: item.id, file: file, destination: .device, placement: placement)
        }
        return item.files.count
    }
}
