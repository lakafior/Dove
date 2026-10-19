import Foundation

/// The single abstraction every storage service implements: debrid services and nzbdav alike.
///
/// Every backend supports the same three user-facing actions:
/// add a source, expose files over WebDAV (handled by the service itself) and download a file to the phone.
public protocol LibraryBackend: Sendable {
    var id: BackendID { get }
    var supportedSources: Set<SourceKind> { get }
    /// Private trackers' torrents may go here: the service keeps seeding (Debrid-Link, TorBox on a paid plan)
    /// and the user lets them in (`PrivateTrackerTarget`). Everyone else refuses them (`TorrentFile.isPrivate`).
    var takesPrivateTorrents: Bool { get }
    /// The service fetches any plain HTTP link into its cloud (a direct download), not only hosters it lists:
    /// Offcloud, TorBox web downloads and Premiumize. Real-Debrid, AllDebrid and Debrid-Link only unlock hosters.
    var acceptsDirectLinks: Bool { get }

    /// Cheap authenticated call used by the "Test connection" button in Settings.
    func validateCredentials() async throws

    /// Adds a source and returns the new item's ID.
    @discardableResult
    func add(_ source: Source) async throws -> LibraryItem.ID

    /// Adds a source filed under `category`, for services that sort jobs into category folders (nzbdav).
    /// Everyone else ignores the category.
    @discardableResult
    func add(_ source: Source, category: AddCategory?) async throws -> LibraryItem.ID

    /// Adds a source that an indexer says comes from a private tracker (`privateTracker`), which a bare magnet
    /// cannot tell. Services that seed only on request (TorBox) ask for it then. Defaults to `add(_:category:)`.
    @discardableResult
    func add(_ source: Source, category: AddCategory?, privateTracker: Bool) async throws -> LibraryItem.ID

    /// Adds a source that may become several items: a hoster's folder link gives one per file (Real-Debrid,
    /// Debrid-Link). Defaults to `add(_:category:privateTracker:)`. The router adds through this.
    @discardableResult
    func addAll(_ source: Source, category: AddCategory?, privateTracker: Bool) async throws -> [LibraryItem.ID]

    func items() async throws -> [LibraryItem]

    /// One item with its file list. Backends whose list endpoint omits files override this.
    func item(_ itemID: LibraryItem.ID) async throws -> LibraryItem

    func delete(_ itemID: LibraryItem.ID) async throws

    /// A ready-to-use request (URL plus any auth headers) for downloading one file to the device.
    func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest
}

extension LibraryBackend {
    @discardableResult
    public func add(_ source: Source, category: AddCategory?) async throws -> LibraryItem.ID {
        try await add(source)
    }

    @discardableResult
    public func add(_ source: Source, category: AddCategory?, privateTracker: Bool) async throws -> LibraryItem.ID {
        if privateTracker, !takesPrivateTorrents { throw BackendError.privateTorrent }
        return try await add(source, category: category)
    }

    @discardableResult
    public func addAll(_ source: Source, category: AddCategory?, privateTracker: Bool) async throws -> [LibraryItem.ID] {
        [try await add(source, category: category, privateTracker: privateTracker)]
    }

    public var takesPrivateTorrents: Bool { false }
    public var acceptsDirectLinks: Bool { false }

    public func supports(_ source: Source) -> Bool {
        supportedSources.contains(source.kind) && (takesPrivateTorrents || !source.isPrivateTorrent)
    }

    /// Throws for a private tracker's torrent on a service that does not seed. Adapters call it before adding.
    func refusePrivateTorrent(_ source: Source) throws {
        if !takesPrivateTorrents, source.isPrivateTorrent { throw BackendError.privateTorrent }
    }

    public func item(_ itemID: LibraryItem.ID) async throws -> LibraryItem {
        guard let match = try await items().first(where: { $0.id == itemID }) else { throw BackendError.notFound }
        return match
    }
}
