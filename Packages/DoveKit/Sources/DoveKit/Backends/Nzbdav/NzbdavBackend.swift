import Foundation

/// nzbdav adapter (stage 3). nzbdav emulates the SABnzbd API and exposes finished jobs over WebDAV.
/// Source: https://github.com/nzbdav-dev/nzbdav
///
/// Plan:
/// - Add: `GET {base}/api?mode=addurl&name=<nzbUrl>&cat=<movies|tv>&apikey=<key>`,
///   or `mode=addfile` with a multipart `.nzb` upload when nzbdav cannot reach the indexer.
/// - Status: `mode=queue` and `mode=history` (failed jobs = missing articles → offer the next NZB).
/// - Files: WebDAV `PROPFIND` (Depth: 1) on `/content/<category>/<job name>/`, Basic Auth with the WebDAV user.
///   Skip `/completed-symlinks` (`.rclonelink` files for *arr apps).
/// - Download: plain `GET` of the WebDAV file URL with an `Authorization: Basic …` header.
/// - Delete: `mode=history&name=delete&value=<nzo_id>` (verify), plus WebDAV delete if read-only is off.
public struct NzbdavBackend: LibraryBackend {
    public let id: BackendID = .nzbdav
    public let supportedSources: Set<SourceKind> = [.nzb]

    private let baseURL: URL
    private let apiKey: String
    private let webDAVUser: String
    private let webDAVPassword: String
    private let transport: any HTTPTransport

    public init(
        baseURL: URL,
        apiKey: String,
        webDAVUser: String,
        webDAVPassword: String,
        transport: any HTTPTransport = URLSession.shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.webDAVUser = webDAVUser
        self.webDAVPassword = webDAVPassword
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
