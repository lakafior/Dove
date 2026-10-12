import Foundation

/// The user's addons, in their order, with the role each one plays:
/// the first addon that can search does search, the first that accepts an ID gives its metadata,
/// and every stream addon that accepts an ID contributes sources.
/// When an AIOStreams Search API login is configured, it replaces that addon's `/stream` route.
public struct AddonSet: Sendable {
    public var addons: [StremioAddon]
    public var aioStreams: AIOStreamsSearch?

    public init(addons: [StremioAddon], aioStreams: AIOStreamsSearch? = nil) {
        self.addons = addons
        self.aioStreams = aioStreams
    }

    public var searchAddon: StremioAddon? {
        addons.first { $0.manifest.canSearch }
    }

    public var canSearch: Bool { searchAddon != nil }

    public var hasStreams: Bool {
        aioStreams != nil || addons.contains { $0.manifest.provides("stream") }
    }

    /// Movies and series matching the query, from the first addon that can search.
    public func search(_ query: String) async throws -> [MediaSummary] {
        guard let addon = searchAddon else { return [] }
        async let movies = addon.search(query, type: .movie)
        async let series = addon.search(query, type: .series)
        return try await interleave(movies, series)
    }

    public func detail(of item: MediaSummary) async throws -> MediaDetail {
        for addon in addons where addon.manifest.accepts("meta", type: item.type, id: item.id) {
            if let detail = try? await addon.meta(type: item.type, id: item.id) { return detail }
        }
        // Nobody knows more: show what the search returned.
        return MediaDetail(summary: item)
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
