import Foundation

/// Searches every enabled indexer in parallel and spends their API hits carefully:
/// - results are kept for `resultLifetime` (reopening a source list costs nothing);
/// - `caps` is asked once and remembered across launches;
/// - hits are counted per indexer per day; at the user's daily limit, or when the indexer says the limit
///   is reached, the indexer is skipped until the next day.
public actor NewznabSearch {
    public struct Results: Sendable {
        public var candidates: [StreamCandidate]
        public var failures: [String]

        /// Names the service that will play the NZBs, like addons do: an indexer only finds them.
        /// nzbdav streams on demand, so its rows count as ready (⚡), as AIOStreams reports them;
        /// TorBox has to download first, so it stays unknown. The indexer's name stays in `label`.
        public func routed(to backend: BackendID?) -> Results {
            var routed = self
            routed.candidates = candidates.map { candidate in
                // Torznab torrents go to the debrid services; their cache status comes from `CacheChecker`.
                guard candidate.kind == .usenet else { return candidate }
                var candidate = candidate
                switch backend {
                case .nzbdav:
                    candidate.service = "nzbdav"
                    candidate.cached = true
                case .torBox:
                    candidate.service = "torbox"
                    candidate.cached = nil
                case .offcloud, .premiumize:
                    candidate.service = backend?.serviceName
                    candidate.cached = nil
                default:
                    candidate.service = nil
                    candidate.cached = nil
                }
                return candidate
            }
            return routed
        }
    }

    /// What the settings screen shows per indexer.
    public struct Usage: Codable, Sendable, Equatable {
        public var day: String
        public var hits: Int
        /// Set when the indexer said its limit is reached.
        public var blocked: Bool
    }

    private struct State: Codable {
        var usage: [String: Usage] = [:]
        var caps: [String: NewznabCaps] = [:]
    }

    private let indexers: [NewznabIndexer]
    private let transport: any HTTPTransport
    private let stateURL: URL?
    private let resultLifetime: TimeInterval
    private let now: @Sendable () -> Date
    private var state: State
    private var results: [String: (date: Date, candidates: [StreamCandidate])] = [:]

    /// - Parameter stateURL: where usage and caps persist (not secret); nil keeps them in memory (tests).
    public init(
        indexers: [NewznabIndexer],
        stateURL: URL?,
        transport: any HTTPTransport = URLSession.shared,
        resultLifetime: TimeInterval = 3600,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.indexers = indexers
        self.transport = transport
        self.stateURL = stateURL
        self.resultLifetime = resultLifetime
        self.now = now
        state = stateURL.flatMap { try? JSONDecoder().decode(State.self, from: Data(contentsOf: $0)) } ?? State()
    }

    public nonisolated var isEmpty: Bool { !indexers.contains(where: \.enabled) }

    /// - Parameter only: the indexer IDs to ask (the search category's sources); nil asks every enabled one.
    public func search(_ query: NewznabQuery, only: Set<String>? = nil) async -> Results {
        let active = indexers.filter { $0.enabled && only?.contains($0.id) != false }
        var candidates: [StreamCandidate] = []
        var failures: [String] = []
        await withTaskGroup(of: (String, Result<[StreamCandidate], any Error>?).self) { group in
            for indexer in active {
                if let cached = results[key(indexer, query)], now().timeIntervalSince(cached.date) < resultLifetime {
                    candidates += cached.candidates
                    continue
                }
                if let reason = blockedReason(indexer) {
                    failures.append("\(indexer.name): \(reason)")
                    continue
                }
                // Caps saved before Dove read `book-search` are asked again for a book search.
                let caps = state.caps[indexer.id].flatMap { query.isBook && $0.bookParams == nil ? nil : $0 }
                // Two hits at most (caps once ever, then the search); reserve them before going out.
                spend(indexer, hits: caps == nil ? 2 : 1)
                let client = NewznabClient(indexer: indexer, transport: transport)
                group.addTask {
                    do {
                        let known: NewznabCaps
                        if let caps { known = caps } else { known = try await client.caps() }
                        await self.remember(caps: known, for: indexer)
                        return (indexer.id, .success(try await client.search(query, caps: known) ?? []))
                    } catch {
                        return (indexer.id, .failure(error))
                    }
                }
            }
            for await (id, outcome) in group {
                guard let outcome, let indexer = active.first(where: { $0.id == id }) else { continue }
                switch outcome {
                case .success(let found):
                    results[key(indexer, query)] = (now(), found)
                    candidates += found
                case .failure(let error):
                    if case NewznabError.limitReached = error { block(indexer) }
                    failures.append("\(indexer.name): \(error.localizedDescription)")
                }
            }
        }
        save()
        return Results(candidates: candidates, failures: failures.sorted())
    }

    /// What a test search found: how many results, and which trackers answered (Jackett's and Prowlarr's
    /// per-result indexer), so a feed pasted under the wrong name shows at once.
    public struct TestResult: Sendable, Equatable {
        public var results: Int
        public var trackers: [String]
    }

    /// Checks the URL and key: `caps`, then a search (many indexers serve caps without a key).
    @discardableResult
    public func test(_ indexer: NewznabIndexer) async throws -> TestResult {
        let client = NewznabClient(indexer: indexer, transport: transport)
        spend(indexer, hits: 2)
        defer { save() }
        let caps = try await client.caps()
        remember(caps: caps, for: indexer)
        let found = try await client.search(.movie(imdbID: "tt0111161", title: "The Shawshank Redemption"), caps: caps) ?? []
        var seen = Set<String>()
        let trackers = found.compactMap(\.tracker).filter { seen.insert($0.lowercased()).inserted }
        return TestResult(results: found.count, trackers: trackers)
    }

    public func usage(of indexer: NewznabIndexer) -> Usage {
        let today = day(now())
        guard let usage = state.usage[indexer.id], usage.day == today else { return Usage(day: today, hits: 0, blocked: false) }
        return usage
    }

    /// Today's usage of every indexer, by ID.
    public func usages() -> [String: Usage] {
        Dictionary(uniqueKeysWithValues: indexers.map { ($0.id, usage(of: $0)) })
    }

    // MARK: - Internals

    private func key(_ indexer: NewznabIndexer, _ query: NewznabQuery) -> String {
        "\(indexer.id)|\(query)"
    }

    private func blockedReason(_ indexer: NewznabIndexer) -> String? {
        let usage = usage(of: indexer)
        if usage.blocked { return "daily limit reached, back tomorrow" }
        if let limit = indexer.dailyLimit, usage.hits >= limit {
            return "used \(usage.hits) of \(limit) daily API hits, back tomorrow"
        }
        return nil
    }

    private func spend(_ indexer: NewznabIndexer, hits: Int) {
        var usage = usage(of: indexer)
        usage.hits += hits
        state.usage[indexer.id] = usage
    }

    private func block(_ indexer: NewznabIndexer) {
        var usage = usage(of: indexer)
        usage.blocked = true
        state.usage[indexer.id] = usage
    }

    private func remember(caps: NewznabCaps, for indexer: NewznabIndexer) {
        state.caps[indexer.id] = caps
    }

    private func save() {
        guard let stateURL, let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
    }

    /// Indexers reset their counters daily; the local calendar day is close enough.
    private func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}
