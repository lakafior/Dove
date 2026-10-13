import Foundation

/// DMM-style fixes for a torrent in the library, by its info hash.
public enum LibraryActions {
    public struct Result: Sendable, Equatable {
        public let backend: BackendID
        public let itemID: LibraryItem.ID
        /// The old item was deleted (always for a reinsert; for a move when asked).
        public let deletedOriginal: Bool
    }

    /// Adds the same torrent again on its service, then deletes the old item: a fresh copy for a dead or expired
    /// torrent, or one stuck in an error. A service that answers with the same item (it keeps one per hash)
    /// gets the old one deleted first and the torrent added again.
    public static func reinsert(_ item: LibraryItem, on backend: any LibraryBackend) async throws -> Result {
        let source = try magnetSource(of: item)
        let newID = try await backend.add(source)
        guard newID == item.id else {
            try await backend.delete(item.id)
            return Result(backend: backend.id, itemID: newID, deletedOriginal: true)
        }
        try await backend.delete(item.id)
        do {
            let readded = try await backend.add(source)
            return Result(backend: backend.id, itemID: readded, deletedOriginal: true)
        } catch {
            throw BackendError.api(
                message: "\(backend.id.displayName) keeps one copy per torrent, so Dove deleted it to add it again, and adding failed: \(error.localizedDescription) Copy the magnet before trying again."
            )
        }
    }

    /// Adds the torrent to another service; deletes it from this one only when asked and only after the add worked.
    public static func move(
        _ item: LibraryItem,
        from source: any LibraryBackend,
        to target: any LibraryBackend,
        deleteOriginal: Bool
    ) async throws -> Result {
        guard source.id != target.id else { throw BackendError.api(message: "It is already on \(target.id.displayName).") }
        let magnet = try magnetSource(of: item)
        guard target.supports(magnet) else { throw BackendError.unsupportedSource(magnet.kind) }
        let newID = try await target.add(magnet)
        if deleteOriginal {
            do {
                try await source.delete(item.id)
            } catch {
                throw BackendError.api(
                    message: "Added to \(target.id.displayName), but deleting it from \(source.id.displayName) failed: \(error.localizedDescription)"
                )
            }
        }
        return Result(backend: target.id, itemID: newID, deletedOriginal: deleteOriginal)
    }

    private static func magnetSource(of item: LibraryItem) throws -> Source {
        guard let magnet = item.magnet else {
            throw BackendError.api(message: "\(item.backend.displayName) did not say which torrent this is, so it cannot be added again.")
        }
        return .magnet(magnet)
    }
}
