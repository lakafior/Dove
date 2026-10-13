import Foundation

/// The user's addons, in their order, with the role each one plays:
/// the first addon that can search does search, the first that accepts an ID gives its metadata,
/// and every stream addon that accepts an ID contributes sources.
/// When an AIOStreams Search API login is configured, it replaces that addon's `/stream` route.
/// With a TMDB key, TMDB searches and describes first; the addons answer when it fails. A series' episodes
/// still come from the metadata addon when one knows the title: stream addons number episodes like
/// Cinemeta/IMDb, and TMDB sometimes splits or merges seasons differently (anime, long-running shows).
public struct AddonSet: Sendable {
    public var addons: [StremioAddon]
    public var aioStreams: AIOStreamsSearch?
    public var tmdb: TMDBMetadata?

    public init(addons: [StremioAddon], aioStreams: AIOStreamsSearch? = nil, tmdb: TMDBMetadata? = nil) {
        self.addons = addons
        self.aioStreams = aioStreams
        self.tmdb = tmdb
    }

    public var searchAddon: StremioAddon? {
        addons.first { $0.manifest.canSearch }
    }

    public var canSearch: Bool { tmdb != nil || searchAddon != nil }

    public var hasStreams: Bool {
        aioStreams != nil || addons.contains { $0.manifest.provides("stream") }
    }

    /// Movies and series matching the query, from TMDB or the first addon that can search.
    public func search(_ query: String) async throws -> [MediaSummary] {
        if let tmdb {
            do { return try await tmdb.search(query) } catch where searchAddon != nil {}
        }
        guard let addon = searchAddon else { return [] }
        async let movies = addon.search(query, type: .movie)
        async let series = addon.search(query, type: .series)
        return try await interleave(movies, series)
    }

    /// One type only, e.g. to match a library item whose release name says it is a series.
    public func search(_ query: String, type: MediaType) async throws -> [MediaSummary] {
        if let tmdb {
            do { return try await tmdb.search(query, type: type) } catch where searchAddon != nil {}
        }
        guard let addon = searchAddon else { return [] }
        return try await addon.search(query, type: type)
    }

    public func detail(of item: MediaSummary) async throws -> MediaDetail {
        if let tmdb, var detail = try? await tmdb.detail(of: item, includeEpisodes: false) {
            guard item.type == .series else { return detail }
            if let episodes = await addonDetail(of: detail.summary)?.episodes, !episodes.isEmpty {
                detail.episodes = episodes
            } else if let full = try? await tmdb.detail(of: item) {
                detail.episodes = full.episodes
            }
            return detail
        }
        // Nobody knows more: show what the search returned.
        return await addonDetail(of: item) ?? MediaDetail(summary: item)
    }

    /// The first metadata addon that accepts the ID and answers.
    private func addonDetail(of item: MediaSummary) async -> MediaDetail? {
        for addon in addons where addon.manifest.accepts("meta", type: item.type, id: item.id) {
            if let detail = try? await addon.meta(type: item.type, id: item.id) { return detail }
        }
        return nil
    }

    public struct Streams: Sendable {
        public var candidates: [StreamCandidate]
        /// Addons or upstream sources that failed, as readable lines.
        public var failures: [String]
    }

    /// Sources for a movie ID or an episode ID (`tt…:season:episode`), from every stream addon in parallel.
    public func streams(type: MediaType, id: String) async -> Streams {
        let streamAddons = addons.filter { addon in
            addon.manifest.accepts("stream", type: type, id: id)
                && !(aioStreams.map { AIOStreamsSearch.instance(from: addon.manifestURL)?.uuid == $0.uuid } ?? false)
        }
        let aio = aioStreams
        return await withTaskGroup(of: (Int, Result<[StreamCandidate], any Error>, [String], String).self) { group in
            if let aio {
                group.addTask {
                    do {
                        let results = try await aio.search(type: type, id: id)
                        return (-1, .success(results.candidates), results.sourceErrors, "AIOStreams")
                    } catch {
                        return (-1, .failure(error), [], "AIOStreams")
                    }
                }
            }
            for (index, addon) in streamAddons.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await addon.streams(type: type, id: id)), [], addon.manifest.name)
                    } catch {
                        return (index, .failure(error), [], addon.manifest.name)
                    }
                }
            }
            var ordered: [(Int, [StreamCandidate])] = []
            var failures: [String] = []
            for await (index, result, sourceErrors, name) in group {
                failures += sourceErrors
                switch result {
                case .success(let candidates): ordered.append((index, candidates))
                case .failure(let error): failures.append("\(name): \(error.localizedDescription)")
                }
            }
            // Keep each addon's own ranking; addons in the user's order, AIOStreams search first.
            let candidates = ordered.sorted { $0.0 < $1.0 }.flatMap(\.1)
            return Streams(candidates: candidates, failures: failures)
        }
    }

    private func interleave(_ a: [MediaSummary], _ b: [MediaSummary]) -> [MediaSummary] {
        var result: [MediaSummary] = []
        for index in 0..<max(a.count, b.count) {
            if index < a.count { result.append(a[index]) }
            if index < b.count { result.append(b[index]) }
        }
        return result
    }
}
