import Foundation

/// Backends that can say, without adding anything, which info hashes they already have cached.
/// TorBox and Offcloud can; Real-Debrid removed its endpoint (only add-and-delete works, and it gets the
/// account paused), so it relies on what addons report.
public protocol CacheChecking: LibraryBackend {
    /// Lowercased info hashes among `hashes` that are cached.
    func cachedHashes(_ hashes: [String]) async throws -> Set<String>
}

public enum CacheChecker {
    /// Asks every checking backend about every info hash in the groups, in parallel,
    /// and records the answers (cached or known-not-cached) in each group's availability.
    public static func annotate(_ groups: [StreamGroup], using backends: [any CacheChecking]) async -> [StreamGroup] {
        let hashes = Array(Set(groups.compactMap { $0.infoHash?.lowercased() }))
        guard !hashes.isEmpty, !backends.isEmpty else { return groups }

        let answers = await withTaskGroup(of: (BackendID, Set<String>?).self) { group in
            for backend in backends {
                group.addTask { (backend.id, try? await backend.cachedHashes(hashes)) }
            }
            var answers: [BackendID: Set<String>] = [:]
            for await (id, cached) in group {
                // A failed check says nothing; leave the rows as the addons described them.
                if let cached { answers[id] = cached }
            }
            return answers
        }

        return groups.map { group in
            guard let hash = group.infoHash?.lowercased() else { return group }
            var group = group
            for (backend, cached) in answers.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                group.record(service: backend.serviceName, cached: cached.contains(hash))
            }
            return group
        }
    }
}

extension BackendID {
    /// The service name addons use, so checked and reported availability share one entry.
    var serviceName: String {
        switch self {
        case .realDebrid: "realdebrid"
        case .torBox: "torbox"
        case .offcloud: "offcloud"
        case .debridLink: "debridlink"
        case .nzbdav: "nzbdav"
        }
    }

    static func chunks(_ hashes: [String], of size: Int) -> [[String]] {
        stride(from: 0, to: hashes.count, by: size).map { Array(hashes[$0..<min($0 + size, hashes.count)]) }
    }
}
