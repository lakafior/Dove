import DoveKit
import Foundation

/// What a source list is for: a movie, an episode, or a whole-season or whole-series pack.
public struct SourceQuery: Sendable {
    public let type: MediaType
    /// The stream ID: `tt…` for a movie, `tt…:<season>:<episode>` for an episode.
    public let id: String
    /// The plain title, for indexers that cannot search by IMDb ID.
    public var searchTitle: String?
    /// When set, only whole-season or whole-series packs are listed.
    public var scope: PackScope?
    /// The movie or series these sources are for: what its library items get matched to (`AddedHint`).
    public var media: MediaSummary?

    public init(type: MediaType, id: String, searchTitle: String? = nil, scope: PackScope? = nil, media: MediaSummary? = nil) {
        self.type = type
        self.id = id
        self.searchTitle = searchTitle
        self.scope = scope
        self.media = media
    }

    /// Which files a download-only add fetches: the episode on screen, every video of a pack, or the movie.
    public var pick: DownloadJob.Pick {
        if scope != nil { return .allVideos }
        if type == .movie { return .largestVideo }
        // Episode IDs are `<series>:<season>:<episode>`.
        let parts = id.split(separator: ":")
        if parts.count >= 3, let season = Int(parts[parts.count - 2]), let episode = Int(parts[parts.count - 1]) {
            return .episode(season: season, episode: episode)
        }
        return .allVideos
    }
}

public struct SourceResults: Sendable {
    public var groups: [StreamGroup]
    /// Addons and indexers that did not answer, with why.
    public var failures: [String]
}

extension AppModel {
    /// Addons and Dove's own indexers in parallel, only those picked in Sources for Movies & TV; NZBs routed to the
    /// Usenet service, one release from several places merged into one group, packs only for a pack scope.
    public func sources(for query: SourceQuery) async -> SourceResults {
        let indexers = indexerIDs(for: .media)
        let newznabQuery = indexers.isEmpty
            ? nil
            : NewznabQuery(type: query.type, id: query.id, title: query.searchTitle, wholeSeason: query.scope != nil)
        async let addonResult = Self.streams(sourceSelection.asksAddons(in: .media) ? addonSet : nil, type: query.type, id: query.id)
        async let usenetResult = Self.search(newznab, newznabQuery, only: indexers)
        let result = await addonResult
        let usenet = await usenetResult?.routed(to: usenetBackend)
        let all = StreamGroup.group((result?.candidates ?? []) + (usenet?.candidates ?? []))
        return SourceResults(
            groups: query.scope.map { scope in all.filter(scope.matches) } ?? all,
            failures: (result?.failures ?? []) + (usenet?.failures ?? [])
        )
    }

    /// The groups with ⚡ per service from the services that can say (TorBox, Offcloud…); nil when none can or no
    /// group has an info hash.
    public func checkingCache(_ groups: [StreamGroup]) async -> [StreamGroup]? {
        let checkers = cacheCheckers
        guard !checkers.isEmpty, groups.contains(where: { $0.infoHash != nil }) else { return nil }
        return await CacheChecker.annotate(groups, using: checkers)
    }

    /// Adds a release. Automatic: services that have it cached first, then the user's priority, falling through on
    /// errors. Or one service only. A private tracker's release that a service has cached goes there as a magnet
    /// (`AddRoute`). With Download only on, the item is then downloaded and removed from the service. Returns what
    /// happened, for the user.
    public func add(_ group: StreamGroup, for query: SourceQuery, only backend: BackendID? = nil) async throws -> String {
        let router = router(preferring: group.cachedBackends())
        guard let route = backend.map({ group.route(to: $0, through: router) }) ?? group.route(through: router) else {
            throw BackendError.api(message: "No service you set up takes this release.")
        }
        // A Torznab result's .torrent link carries the indexer's key: fetch it here, never hand it over.
        let source = try await IndexerTorrent.prepare(route.source)
        let added: BackendID
        let itemID: LibraryItem.ID
        var itemIDs: [LibraryItem.ID] = []
        var skipped: [String] = []
        // NZBs land in nzbdav's `movies` or `tv` folder.
        let category = AddCategory(mediaType: query.type)
        if let backend, let service = self.backend(backend) {
            // An indexer said private: the magnet cannot tell, so the service checks (and TorBox seeds it).
            itemID = try await service.add(source, category: category, privateTracker: route.privateTracker)
            itemIDs = [itemID]
            added = backend
        } else {
            let result = try await route.router.add(source, category: category)
            added = result.backend
            itemID = result.itemID
            itemIDs = result.itemIDs
            skipped = result.skipped.map { "\($0.backend.displayName): \($0.error.localizedDescription)" }
        }
        library.recordAdded(
            AddedHint(releaseName: group.releaseName, media: query.media),
            backend: added, itemIDs: itemIDs, infoHash: group.infoHash
        )
        let message = downloadOnly
            ? await startDownloadOnly(itemID, on: added, name: group.folderName ?? group.title, pick: query.pick)
            : "Added to \(added.displayName)."
        return ([message] + skipped).joined(separator: "\n")
    }

    private static func search(_ newznab: NewznabSearch, _ query: NewznabQuery?, only: Set<String>) async -> NewznabSearch.Results? {
        guard let query else { return nil }
        return await newznab.search(query, only: only)
    }

    private static func streams(_ addons: AddonSet?, type: MediaType, id: String) async -> AddonSet.Streams? {
        await addons?.streams(type: type, id: id)
    }
}
