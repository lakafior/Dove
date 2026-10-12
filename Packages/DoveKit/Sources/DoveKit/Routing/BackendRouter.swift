import Foundation

/// Picks the backend for a source. The source type decides the family
/// (torrent/hoster go to debrid, NZB goes to nzbdav); the user's priority order decides within it.
public struct BackendRouter: Sendable {
    public var backends: [any LibraryBackend]
    /// Highest priority first. Backends missing from the list keep their relative order after the listed ones.
    public var order: [BackendID]

    public init(backends: [any LibraryBackend], order: [BackendID] = []) {
        self.backends = backends
        self.order = order
    }

    /// Compatible backends, in priority order.
    public func candidates(for source: Source) -> [any LibraryBackend] {
        let compatible = backends.filter { $0.supports(source) }
        let rank = { (id: BackendID) in order.firstIndex(of: id) ?? order.count }
        return compatible.enumerated()
            .sorted { (rank($0.element.id), $0.offset) < (rank($1.element.id), $1.offset) }
            .map(\.element)
    }

    public func backend(for source: Source) throws -> any LibraryBackend {
        guard let first = candidates(for: source).first else {
            throw BackendError.unsupportedSource(source.kind)
        }
        return first
    }

    public struct Failure: Sendable {
        public let backend: BackendID
        public let error: any Error
    }

    public struct AddResult: Sendable {
        public let backend: BackendID
        public let itemID: LibraryItem.ID
        /// Backends tried before the one that took the source, with what they answered.
        public let skipped: [Failure]
    }

    /// Tries compatible backends in priority order until one accepts the source.
    /// Any error moves on to the next backend, except cancellation.
    public func add(_ source: Source) async throws -> AddResult {
        let candidates = candidates(for: source)
        guard !candidates.isEmpty else { throw BackendError.unsupportedSource(source.kind) }
        var failures: [Failure] = []
        for backend in candidates {
            try Task.checkCancellation()
            do {
                let id = try await backend.add(source)
                return AddResult(backend: backend.id, itemID: id, skipped: failures)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(Failure(backend: backend.id, error: error))
            }
        }
        throw RoutingError.allFailed(failures)
    }
}

public enum RoutingError: Error, LocalizedError {
    case allFailed([BackendRouter.Failure])

    public var errorDescription: String? {
        switch self {
        case .allFailed(let failures):
            failures
                .map { "\($0.backend.displayName): \($0.error.localizedDescription)" }
                .joined(separator: "\n")
        }
    }
}
