import Foundation

/// DMM-style fixes for a library item: add it again (a fresh copy of a dead torrent, a retry of a failed NZB)
/// or move it to another service. Torrents go by info hash; NZBs need a backend that hands them back
/// (`NZBProviding`: nzbdav with its frontend key).
public enum LibraryActions {
    public struct Result: Sendable, Equatable {
        public let backend: BackendID
        public let itemID: LibraryItem.ID
        /// The old item was deleted (always for a reinsert; for a move when asked).
        public let deletedOriginal: Bool
    }

    /// Whether the item can be added again or moved: a torrent with its hash, or an NZB its service can return.
    public static func canReAdd(_ item: LibraryItem, on backend: (any LibraryBackend)?) -> Bool {
        if item.magnet != nil { return true }
        guard let provider = backend as? any NZBProviding else { return false }
        return provider.providesNZB(for: item)
    }

    /// Adds the item again on its service and deletes the old one.
    ///
    /// Torrents: add first, then delete, so nothing is lost if the add fails. A service that answers with the
    /// same item (one per hash) gets delete-then-add instead.
    /// NZBs: a failed job is retried by the server when it can (InfiniDysk `mode=retry`, which keeps the category),
    /// then the old entry is removed. Otherwise the NZB is fetched first and the old job deleted before the add,
    /// because nzbdav names the new job's folder after the NZB, the same as the old one's.
    public static func reinsert(_ item: LibraryItem, on backend: any LibraryBackend) async throws -> Result {
        if item.magnet == nil, case .failed = item.status,
           let provider = backend as? any NZBProviding, provider.providesNZB(for: item),
           let newID = try await provider.retry(item) {
            do {
                try await backend.delete(item.id)
            } catch {
                throw BackendError.api(
                    message: "The job was retried, but removing the failed entry failed: \(error.localizedDescription)"
                )
            }
            return Result(backend: backend.id, itemID: newID, deletedOriginal: true)
        }
        let source = try await source(of: item, from: backend)
        if case .magnet = source {
            let newID = try await backend.add(source)
            guard newID == item.id else {
                try await backend.delete(item.id)
                return Result(backend: backend.id, itemID: newID, deletedOriginal: true)
            }
        }
        try await backend.delete(item.id)
        do {
            let readded = try await backend.add(source)
            return Result(backend: backend.id, itemID: readded, deletedOriginal: true)
        } catch {
            let what = source.kind == .nzb ? "the job" : "it"
            throw BackendError.api(
                message: "Dove deleted \(what) on \(backend.id.displayName) to add it again, and adding failed: \(error.localizedDescription)"
            )
        }
    }

    /// Adds the item to another service; deletes it from this one only when asked and only after the add worked.
    public static func move(
        _ item: LibraryItem,
        from source: any LibraryBackend,
        to target: any LibraryBackend,
        deleteOriginal: Bool
    ) async throws -> Result {
        guard source.id != target.id else { throw BackendError.api(message: "It is already on \(target.id.displayName).") }
        let added = try await self.source(of: item, from: source)
        guard target.supports(added) else { throw BackendError.unsupportedSource(added.kind) }
        let newID = try await target.add(added)
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

    /// What the item can be added from: its magnet, or the NZB its service returns.
    static func source(of item: LibraryItem, from backend: any LibraryBackend) async throws -> Source {
        if let magnet = item.magnet { return .magnet(magnet) }
        if let provider = backend as? any NZBProviding, provider.providesNZB(for: item) {
            return try await provider.nzb(of: item)
        }
        throw BackendError.api(message: "\(item.backend.displayName) did not say which torrent or NZB this is, so it cannot be added again.")
    }

    /// The kind of source an item would be re-added from, without fetching it (for picking move targets).
    public static func sourceKind(of item: LibraryItem) -> SourceKind? {
        if item.magnet != nil { return .torrent }
        if item.nzbBlobID != nil { return .nzb }
        return nil
    }
}
