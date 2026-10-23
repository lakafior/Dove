import AppKit
import DoveAppCore
import DoveKit
import SwiftUI

/// The releases on an item screen (`MacItemView`): the files each one lists once asked for, the dialogs its changes
/// ask first, and the changes themselves. What each does is the iPhone's `LibraryItemView` action, unchanged; only
/// where it is offered moved (into the release's and the file's context menus).
@MainActor
@Observable
final class ReleaseStore {
    /// Releases as their service answered when their files were asked for, by shelf item ID.
    private(set) var details: [ShelfItem.ID: LibraryItem] = [:]
    private(set) var loadErrors: [ShelfItem.ID: String] = [:]
    private(set) var loading: Set<ShelfItem.ID> = []

    /// What the screen shows as an alert (copies, changes, errors).
    var message: String?
    /// Waiting for the user: a delete, a reinsert and a move are confirmed before they run.
    var pendingDelete: [ShelfItem] = []
    var pendingReinsert: ShelfItem?
    var pendingMove: PendingMove?
    /// A torrent waiting for its files to be picked on the service (Real-Debrid), shown as a sheet.
    var choosingFiles: ShelfItem?

    /// A release to move to another service once the user confirms.
    struct PendingMove {
        let item: ShelfItem
        let target: BackendID
    }

    /// The release as the screen shows it: the service's answer when it has one, else the library's.
    func current(_ item: ShelfItem) -> LibraryItem { details[item.id] ?? item.item }

    /// "Listing the files…" while asked for, the error, or "No files yet." once asked and empty.
    func fileNote(_ item: ShelfItem) -> String {
        if let error = loadErrors[item.id] { return error }
        if loading.contains(item.id) || (details[item.id] == nil && item.item.files.isEmpty) { return "Listing the files…" }
        return "No files yet."
    }

    /// Lists the files of releases that came without them (the library's rows do not carry them for every service).
    func loadFiles(_ items: [ShelfItem], using model: AppModel) async {
        for item in items where item.item.files.isEmpty && details[item.id] == nil && !loading.contains(item.id) {
            guard let backend = model.backend(item.item.backend) else {
                loadErrors[item.id] = "\(item.item.backend.displayName) is no longer configured."
                continue
            }
            loading.insert(item.id)
            do {
                details[item.id] = try await backend.item(item.item.id)
                loadErrors[item.id] = nil
            } catch {
                loadErrors[item.id] = error.localizedDescription
            }
            loading.remove(item.id)
        }
    }

    /// Video and audio the user's player takes (Ogg and Opus do not play on Apple platforms).
    static func canPlay(_ name: String) -> Bool {
        FileKind.isVideo(name) || AudiobookTracks.playableExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    // MARK: Copies

    /// Puts text on the pasteboard, with a confirmation when given.
    func copy(_ text: String, confirmation: String? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if let confirmation { message = confirmation }
    }

    /// The service's playback link for a file (the same one-line link iOS copies).
    func copyLink(_ file: LibraryFile, of item: ShelfItem, using model: AppModel) {
        Task {
            let release = current(item)
            guard let backend = model.backend(release.backend) else { return }
            do {
                let url = try await backend.playbackURL(itemID: release.id, fileID: file.id)
                copy(url.absoluteString, confirmation: "Link copied.")
            } catch {
                self.message = error.localizedDescription
            }
        }
    }

    // MARK: Playing and downloading

    /// Plays one file in the user's player: the service's link, named after the file.
    func play(_ file: LibraryFile, of item: ShelfItem, in player: ExternalPlayer? = nil, using model: AppModel) {
        Task {
            let release = current(item)
            guard let backend = model.backend(release.backend) else { return }
            do {
                // nzbdav's link carries the WebDAV login; the file name lets Infuse recognise the episode.
                let url = try await backend.playbackURL(itemID: release.id, fileID: file.id)
                try await model.playback.play([PlayEntry(url: url, filename: (file.name as NSString).lastPathComponent)], in: player)
            } catch {
                self.message = error.localizedDescription
            }
        }
    }

    /// Downloads one file to this Mac's Downloads (progress is in the Downloads page).
    func download(_ file: LibraryFile, of item: ShelfItem, using model: AppModel) {
        Task {
            do {
                try await model.download(file, of: current(item), to: .device)
            } catch {
                self.message = error.localizedDescription
            }
        }
    }

    /// One file into iCloud Drive › Dove, filed by the Library's layout (as the iPhone's "Save to iCloud Drive").
    func saveToICloud(_ file: LibraryFile, of item: ShelfItem, using model: AppModel) {
        Task {
            do {
                try await model.download(file, of: current(item), to: .iCloud)
            } catch {
                self.message = error.localizedDescription
            }
        }
    }

    /// Every file of the ready release, to the place its kind goes (`AppModel.downloadItem`).
    func downloadAll(_ item: ShelfItem, using model: AppModel) {
        Task {
            do {
                try await model.downloadItem(item)
            } catch {
                self.message = error.localizedDescription
            }
        }
    }

    /// Selects the file in the Finder, after iCloud Drive has it locally.
    func reveal(_ file: LibraryFile, of item: ShelfItem, using model: AppModel) {
        Task {
            let release = current(item)
            guard let backend = model.backend(release.backend) else { return }
            do {
                if let url = try await backend.downloadRequest(itemID: release.id, fileID: file.id).url {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                self.message = error.localizedDescription
            }
        }
    }

    // MARK: Release changes

    /// Fetches the release again from its service (the Refresh Status action).
    func refreshStatus(_ item: ShelfItem, using model: AppModel) {
        Task {
            guard let backend = model.backend(item.item.backend) else { return }
            do {
                let loaded = try await backend.item(item.item.id)
                details[item.id] = loaded
                model.library.learnKind(from: loaded)
                message = "Status: \(loaded.status.label)."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func reinsert(_ item: ShelfItem, using model: AppModel) {
        guard let backend = model.backend(item.item.backend) else { return }
        let release = current(item)
        runAction(using: model) {
            _ = try await LibraryActions.reinsert(release, on: backend)
        }
    }

    func move(_ item: ShelfItem, to target: BackendID, deleteOriginal: Bool, using model: AppModel) {
        guard let source = model.backend(item.item.backend), let destination = model.backend(target) else { return }
        let release = current(item)
        runAction(using: model) {
            _ = try await LibraryActions.move(release, from: source, to: destination, deleteOriginal: deleteOriginal)
            if !deleteOriginal { self.message = "Added to \(target.displayName)." }
        }
    }

    /// "Automatic" clears what the user set; a kind sets it (`LibraryModel.setKind`).
    func setKind(_ kind: ContentKind?, for item: ShelfItem, using model: AppModel) {
        Task { await model.library.setKind(kind, for: [item], using: model) }
    }

    /// Runs a change on the service, then refreshes the library (the release leaves the screen once it is gone); an
    /// error goes to the alert.
    private func runAction(using model: AppModel, _ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                self.message = error.localizedDescription
            }
            await model.library.refresh(using: model, afterChange: true)
        }
    }
}
