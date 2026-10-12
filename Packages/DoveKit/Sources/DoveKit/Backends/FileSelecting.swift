import Foundation

/// Backends where an added torrent can wait for the user to pick its files (status `.awaitingFileSelection`).
/// Real-Debrid does: Dove selects video files right after adding, but gives up if the magnet takes
/// longer to convert, and the torrent then waits until someone chooses.
public protocol FileSelecting: LibraryBackend {
    /// Every file of a waiting item, with the ones Dove would pick.
    func selectableFiles(_ itemID: LibraryItem.ID) async throws -> FileSelection

    /// Starts the download of the chosen files. Throws for an empty selection.
    func selectFiles(_ itemID: LibraryItem.ID, fileIDs: Set<LibraryFile.ID>) async throws
}

public struct FileSelection: Sendable, Hashable {
    public var files: [LibraryFile]
    /// Video files without samples; every file when the torrent has no video.
    public var suggested: Set<LibraryFile.ID>

    public init(files: [LibraryFile], suggested: Set<LibraryFile.ID>) {
        self.files = files
        self.suggested = suggested
    }
}
