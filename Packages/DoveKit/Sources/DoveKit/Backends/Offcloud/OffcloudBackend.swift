import Foundation

/// Offcloud adapter (stage 1, after Real-Debrid). API docs: https://offcloud.com/api
///
/// Plan:
/// - Auth: `key=<apiKey>` query item.
/// - Add magnet or hoster link: `POST /api/cloud` with `url` (cloud download) → `requestId`.
/// - Status: `POST /api/cloud/status` with `requestIds`. History: `GET /api/cloud/history`.
/// - Files: `GET /api/cloud/explore/{requestId}` lists direct file URLs.
/// - Delete: `GET /cloud/remove/{requestId}`.
public struct OffcloudBackend: LibraryBackend {
    public let id: BackendID = .offcloud
    public let supportedSources: Set<SourceKind> = [.torrent, .hoster]

    private let apiKey: String
    private let transport: any HTTPTransport

    public init(apiKey: String, transport: any HTTPTransport = URLSession.shared) {
        self.apiKey = apiKey
        self.transport = transport
    }

    public func validateCredentials() async throws { throw BackendError.notImplemented }
    public func add(_ source: Source) async throws -> LibraryItem.ID { throw BackendError.notImplemented }
    public func items() async throws -> [LibraryItem] { throw BackendError.notImplemented }
    public func delete(_ itemID: LibraryItem.ID) async throws { throw BackendError.notImplemented }
    public func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest {
        throw BackendError.notImplemented
    }
}
