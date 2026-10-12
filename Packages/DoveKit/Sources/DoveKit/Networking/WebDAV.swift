import Foundation

/// One entry of a WebDAV `PROPFIND` answer.
public struct WebDAVEntry: Sendable, Hashable {
    /// Decoded path on the server, without scheme and host (`/content/Tv/Show/file.mkv`).
    public var path: String
    public var isDirectory: Bool
    public var size: Int64?
    public var modified: Date?

    public var name: String { (path as NSString).lastPathComponent }
}

/// `PROPFIND` with Basic Auth, parsed with `XMLParser`. Servers behind a reverse proxy answer with their
/// internal host (`http://localhost:8080/...`), so only the path of each `href` is kept.
struct WebDAVClient: Sendable {
    let baseURL: URL
    let user: String
    let password: String
    let transport: any HTTPTransport

    var authorization: String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    /// The URL of a server path, percent-encoded.
    func url(for path: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + (path.hasPrefix("/") ? path : "/" + path)
        // `path` encodes spaces and the like, but leaves `?`, `#` and `;` alone in some cases: encode those too.
        components.percentEncodedPath = components.percentEncodedPath
            .replacingOccurrences(of: "?", with: "%3F")
            .replacingOccurrences(of: "#", with: "%23")
            .replacingOccurrences(of: ";", with: "%3B")
        return components.url!
    }

    /// The direct children of a directory (the directory itself is left out).
    func list(_ path: String) async throws -> [WebDAVEntry] {
        var request = URLRequest(url: url(for: path.hasSuffix("/") ? path : path + "/"))
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <propfind xmlns="DAV:"><prop><resourcetype/><getcontentlength/><getlastmodified/></prop></propfind>
            """.utf8)
        let (data, response) = try await transport.send(request)
        if response.statusCode == 401 || response.statusCode == 403 {
            throw BackendError.api(message: "WebDAV refused the user name or password.")
        }
        if let error = response.backendError { throw error }
        let own = Self.normalized(path)
        return WebDAVResponseParser.parse(data).filter { Self.normalized($0.path) != own }
    }

    /// `DELETE` a file or folder. A refusal stays `.http(status: 403)` (the server forbids it, e.g. read-only),
    /// apart from a wrong login (401).
    func delete(_ path: String) async throws {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "DELETE"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let (_, response) = try await transport.send(request)
        switch response.statusCode {
        case 200..<300: return
        case 401: throw BackendError.api(message: "WebDAV refused the user name or password.")
        case 403: throw BackendError.http(status: 403)
        default: throw response.backendError ?? BackendError.invalidResponse
        }
    }

    /// Every file under a directory, a few levels deep (season packs keep episodes in subfolders).
    func files(under path: String, depth: Int = 3) async throws -> [WebDAVEntry] {
        var result: [WebDAVEntry] = []
        for entry in try await list(path) {
            if entry.isDirectory {
                if depth > 1 { result += try await files(under: entry.path, depth: depth - 1) }
            } else {
                result.append(entry)
            }
        }
        return result
    }

    static func normalized(_ path: String) -> String {
        var path = path
        while path.hasSuffix("/") && path.count > 1 { path.removeLast() }
        return path
    }
}

/// Reads `multistatus` responses whatever the namespace prefix (`D:`, `d:`, none).
final class WebDAVResponseParser: NSObject, XMLParserDelegate {
    private var entries: [WebDAVEntry] = []
    private var href = ""
    private var size: Int64?
    private var modified: Date?
    private var isDirectory = false
    private var text = ""

    static func parse(_ data: Data) -> [WebDAVEntry] {
        let delegate = WebDAVResponseParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "response":
            href = ""
            size = nil
            modified = nil
            isDirectory = false
        case "collection":
            isDirectory = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "href": href = value
        case "getcontentlength": size = Int64(value)
        case "getlastmodified": modified = Self.dateFormatter.date(from: value)
        case "iscollection": if value == "1" { isDirectory = true }
        case "response":
            if let path = Self.path(of: href) {
                entries.append(WebDAVEntry(path: path, isDirectory: isDirectory, size: isDirectory ? nil : size, modified: modified))
            }
        default:
            break
        }
        text = ""
    }

    /// `http://localhost:8080/content/A%20B/` → `/content/A B/`.
    static func path(of href: String) -> String? {
        guard !href.isEmpty else { return nil }
        var raw = href
        if let range = raw.range(of: "://") {
            let afterScheme = raw[range.upperBound...]
            raw = afterScheme.firstIndex(of: "/").map { String(afterScheme[$0...]) } ?? "/"
        }
        return raw.removingPercentEncoding ?? raw
    }
}
