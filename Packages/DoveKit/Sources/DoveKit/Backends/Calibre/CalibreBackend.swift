import Foundation

/// The user's Calibre library through its Content server (`calibre-server`, or Calibre › Connect/share): a place the
/// user keeps books, listed like a service. Each book is an item (`calibre:<book id>`), each of its formats a file
/// (`epub`, `pdf`…), and the book carries Calibre's own metadata (`LibraryItem.book`), so the Library shows it
/// without looking it up anywhere else.
///
/// API: the JSON endpoints Calibre's own web app uses (not formally documented, stable for years):
/// `ajax/library-info` (libraries), `ajax/search/<library>` (book IDs, newest first), `ajax/books/<library>?ids=`
/// (metadata, formats with sizes), `get/<format>/<id>/<library>` (a file), `get/thumb/<id>/<library>` (a cover).
///
/// Addresses: at home and away (Tailscale), tried in that order; the first that answers is used until it stops
/// answering. Login is optional: without it Calibre serves read-only, which is all listing and downloading need;
/// with "Require username and password" on, every request needs it (Basic auth: set the server's authentication
/// type to basic, Calibre answers digest by default over plain HTTP).
public struct CalibreBackend: LibraryBackend {
    public let id: BackendID = .calibre
    let addresses: CalibreAddresses
    let user: String
    let password: String
    /// A library of the server's; nil takes its default one.
    let libraryID: String?
    private let transport: any HTTPTransport

    /// Book IDs asked about in one `ajax/books` call.
    static let batchSize = 200
    /// Formats Dove treats as audiobooks (Calibre can keep `m4b` files too).
    static let audioFormats: Set<String> = ["m4b", "m4a", "mp3", "aac", "flac", "ogg", "opus"]

    public init(
        addresses: [URL],
        user: String = "",
        password: String = "",
        libraryID: String? = nil,
        transport: any HTTPTransport = URLSession.shared
    ) {
        self.addresses = CalibreAddresses(addresses)
        self.user = user
        self.password = password
        self.libraryID = libraryID.flatMap { $0.isEmpty ? nil : $0 }
        self.transport = transport
    }

    public var supportedSources: Set<SourceKind> { [] }

    public func validateCredentials() async throws {
        _ = try await library()
    }

    public func add(_ source: Source) async throws -> LibraryItem.ID {
        throw BackendError.unsupportedSource(source.kind)
    }

    public func delete(_ itemID: LibraryItem.ID) async throws {
        throw BackendError.api(message: "Dove does not delete books from Calibre. Remove it in Calibre itself.")
    }

    // MARK: - Listing

    public func items() async throws -> [LibraryItem] {
        let library = try await library()
        let search: CalibreSearch = try await get("ajax/search/\(library)", [
            URLQueryItem(name: "num", value: "1000000"),
            URLQueryItem(name: "sort", value: "timestamp"),
            URLQueryItem(name: "sort_order", value: "desc"),
        ])
        var items: [LibraryItem] = []
        for start in stride(from: 0, to: search.bookIDs.count, by: Self.batchSize) {
            let ids = search.bookIDs[start..<min(start + Self.batchSize, search.bookIDs.count)]
            let books: [String: CalibreBook?] = try await get("ajax/books/\(library)", [
                URLQueryItem(name: "ids", value: ids.map(String.init).joined(separator: ",")),
            ])
            for id in ids {
                if let book = books[String(id)] ?? nil { items.append(item(book, id: id, library: library)) }
            }
        }
        return items
    }

    public func item(_ itemID: LibraryItem.ID) async throws -> LibraryItem {
        guard let id = Self.bookID(itemID) else { throw BackendError.notFound }
        let library = try await library()
        let books: [String: CalibreBook?] = try await get("ajax/books/\(library)", [URLQueryItem(name: "ids", value: String(id))])
        guard let book = books[String(id)] ?? nil else { throw BackendError.notFound }
        return item(book, id: id, library: library)
    }

    func item(_ book: CalibreBook, id: Int, library: String) -> LibraryItem {
        let authors = Self.authors(book.authors)
        let title = book.title ?? "Book \(id)"
        let author = authors.first
        let formats = book.formats ?? []
        let files = formats.map { format in
            LibraryFile(
                id: format.lowercased(),
                name: "\(LibraryFolderLayout.itemName(author: author ?? "", title: title)).\(format.lowercased())",
                size: book.formatMetadata?[format.lowercased()]?.size
            )
        }
        let isAudio = !formats.isEmpty && formats.allSatisfy { Self.audioFormats.contains($0.lowercased()) }
        return LibraryItem(
            id: "calibre:\(id)",
            backend: self.id,
            name: author.map { LibraryFolderLayout.itemName(author: $0, title: title) } ?? title,
            size: files.compactMap(\.size).reduce(0, +),
            status: .ready,
            files: files,
            addedAt: book.timestamp.flatMap(Self.date),
            kindHint: isAudio ? .audiobooks : .books,
            book: BookSummary(
                id: "calibre:\(id)",
                title: title,
                authors: authors,
                year: book.pubdate.flatMap(Self.year),
                cover: book.cover == nil ? nil : Self.coverURL(library: library, bookID: id, version: book.lastModified),
                description: book.comments.flatMap(Self.plainText)
            )
        )
    }

    // MARK: - Files and covers

    public func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest {
        guard let id = Self.bookID(itemID) else { throw BackendError.notFound }
        let library = try await library()
        return request(await addresses.preferred(), "get/\(fileID)/\(id)/\(library)")
    }

    /// `calibre://cover/<library>/<id>?v=<last modified>`: the same URL at home and away, without the login, so the
    /// image cache keeps one copy per cover and a changed cover gets a new URL. `ImageCache` asks `coverRequest`
    /// for the real request.
    public static let coverScheme = "calibre"

    static func coverURL(library: String, bookID: Int, version: String?) -> URL? {
        var components = URLComponents()
        components.scheme = coverScheme
        components.host = "cover"
        components.path = "/\(library)/\(bookID)"
        if let version { components.queryItems = [URLQueryItem(name: "v", value: version)] }
        return components.url
    }

    /// The server's thumbnail for a `calibre://cover/…` URL, at the address that answers, with the login.
    public func coverRequest(for url: URL) async throws -> URLRequest {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard url.scheme == Self.coverScheme, url.host == "cover", parts.count == 2, Int(parts[1]) != nil else {
            throw BackendError.notFound
        }
        return request(await addresses.preferred(), "get/thumb/\(parts[1])/\(parts[0])", [URLQueryItem(name: "sz", value: "400x600")])
    }

    // MARK: - Adding

    /// What `/cdb/add-book` answered: the new book's ID, or the books Calibre thinks are the same one.
    public struct AddResult: Sendable, Equatable {
        public var bookID: Int?
        /// "Title — Author" of each book Calibre found alike; empty when it added the book.
        public var duplicates: [String]
    }

    /// Uploads a book file; Calibre reads its metadata from the file and files it under Author/Title itself.
    /// Without `allowDuplicate` a book Calibre already holds is not added and comes back in `duplicates`.
    public func addBook(file: URL, fileName: String, allowDuplicate: Bool = false) async throws -> AddResult {
        let library = try await library()
        let data = try Data(contentsOf: file)
        // One path component: Calibre keeps only the name's extension and sanitises the rest.
        let fileName = fileName.replacingOccurrences(of: "/", with: "_")
        let answer: CalibreAddAnswer = try await perform(
            "cdb/add-book/\(UUID().uuidString.prefix(8))/\(allowDuplicate ? "y" : "n")/\(fileName)/\(library)",
            body: data,
            contentType: "application/octet-stream",
            timeout: 120
        )
        return AddResult(
            bookID: answer.bookID,
            duplicates: (answer.duplicates ?? []).map { duplicate in
                ([duplicate.title] + [Self.authors(duplicate.authors).first]).compactMap { $0 }.joined(separator: " — ")
            }
        )
    }

    /// Replaces what Calibre read from the file with the book the user picked in Dove: title, authors,
    /// description and, when given, cover (JPEG or PNG; others are left to Calibre). Other fields (ISBN,
    /// publisher, language, publication date) stay as Calibre read them.
    public func setMetadata(bookID: Int, book: BookSummary, cover: Data?) async throws {
        let library = try await library()
        var changes: [String: CalibreFieldValue] = ["title": .text(book.title)]
        if !book.authors.isEmpty { changes["authors"] = .list(book.authors) }
        if let description = book.description { changes["comments"] = .text(Self.html(description)) }
        if let cover, let type = Self.imageType(cover) {
            changes["cover"] = .text("data:image/\(type);base64,\(cover.base64EncodedString())")
        }
        let body = try JSONEncoder().encode(CalibreSetFields(changes: changes, loadedBookIDs: [bookID]))
        let _: CalibreIgnored = try await perform("cdb/set-fields/\(bookID)/\(library)", body: body, contentType: "application/json", timeout: 30)
    }

    /// Plain text to the HTML Calibre keeps descriptions in.
    static func html(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .components(separatedBy: "\n\n")
            .map { "<p>\($0.replacingOccurrences(of: "\n", with: "<br>"))</p>" }
            .joined()
    }

    /// Calibre takes JPEG and PNG covers only.
    static func imageType(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpeg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        return nil
    }

    // MARK: - HTTP

    private func library() async throws -> String {
        if let libraryID { return libraryID }
        let info: CalibreLibraryInfo = try await get("ajax/library-info")
        return info.defaultLibrary
    }

    private func request(_ base: URL, _ path: String, _ query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        if !user.isEmpty {
            let login = Data("\(user):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(login)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        try await perform(path, query)
    }

    /// Tries the addresses in order, starting with the last one that answered. Only a network failure moves on
    /// to the next address; an answer from the server (a refused login, a missing book) is final.
    private func perform<T: Decodable>(
        _ path: String,
        _ query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil,
        timeout: TimeInterval = 8
    ) async throws -> T {
        var failures: [(host: String, error: URLError)] = []
        for base in await addresses.ordered() {
            var request = request(base, path, query)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.httpMethod = "POST"
                request.httpBody = body
                if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            }
            // A home address away from home should give up quickly; an upload needs longer.
            request.timeoutInterval = timeout
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch let error as URLError {
                failures.append((base.host() ?? base.absoluteString, error))
                continue
            }
            await addresses.answered(base)
            if response.statusCode == 401 {
                throw BackendError.api(message: user.isEmpty
                    ? "Calibre asks for a login: enter the user and password of an account in Calibre's sharing settings."
                    : "Calibre refused the login. Check the user and password, and that the server's authentication type is basic.")
            }
            if response.statusCode == 403 {
                throw BackendError.api(message: "Calibre refused the change: the account may only read. Untick read-only for it in Calibre's sharing settings (User accounts).")
            }
            if let error = response.backendError { throw error }
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw BackendError.invalidResponse
            }
        }
        throw BackendError.api(message: "Calibre did not answer. " + failures.map { "\($0.host): \(Self.reason($0.error))" }.joined(separator: " "))
    }

    /// Why an address did not answer, in words that say what to change.
    static func reason(_ error: URLError) -> String {
        switch error.code {
        case .appTransportSecurityRequiresSecureConnection:
            "iOS allows plain http only on the local network (an IP address or a .local name); use https for this address (e.g. tailscale serve)."
        case .timedOut: "no answer in time (not on this network?)."
        case .cannotFindHost, .dnsLookupFailed: "name not found (not on this network?)."
        case .cannotConnectToHost: "nothing listens on that port (is the Calibre server running?)."
        case .notConnectedToInternet: "no network connection."
        default: error.localizedDescription
        }
    }

    // MARK: - Parsing

    static func bookID(_ itemID: LibraryItem.ID) -> Int? {
        guard itemID.hasPrefix("calibre:") else { return nil }
        return Int(itemID.dropFirst("calibre:".count))
    }

    /// Calibre keeps authors as a list; libraries imported from elsewhere sometimes hold "A;B" in one entry.
    static func authors(_ authors: [String]?) -> [String] {
        (authors ?? [])
            .flatMap { $0.split(separator: ";") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "Unknown" && $0 != "Nieznany" }
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// Calibre writes an unknown date as year 101.
    static func year(_ text: String) -> Int? {
        guard let year = Int(text.prefix(4)), year > 1000 else { return nil }
        return year
    }

    /// Comments are HTML.
    static func plainText(_ html: String) -> String? {
        let text = html
            .replacingOccurrences(of: "<br\\s*/?>|</p>|</div>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// The server's addresses (home, then away) and which one answered last.
actor CalibreAddresses {
    let all: [URL]
    private var current: URL?

    init(_ addresses: [URL]) {
        all = addresses
    }

    /// The one that answered last first, then the rest in the user's order.
    func ordered() -> [URL] {
        guard let current else { return all }
        return [current] + all.filter { $0 != current }
    }

    func preferred() -> URL {
        current ?? all[0]
    }

    func answered(_ url: URL) {
        current = url
    }
}

// MARK: - Wire types

struct CalibreAddAnswer: Decodable {
    struct Duplicate: Decodable {
        let title: String?
        let authors: [String]?
    }

    let bookID: Int?
    let duplicates: [Duplicate]?

    enum CodingKeys: String, CodingKey {
        case duplicates
        case bookID = "book_id"
    }
}

enum CalibreFieldValue: Encodable, Equatable {
    case text(String)
    case list([String])

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .list(let list): try container.encode(list)
        }
    }
}

struct CalibreSetFields: Encodable {
    let changes: [String: CalibreFieldValue]
    let loadedBookIDs: [Int]

    enum CodingKeys: String, CodingKey {
        case changes
        case loadedBookIDs = "loaded_book_ids"
    }
}

/// Any JSON answer whose content Dove does not need.
struct CalibreIgnored: Decodable {}

struct CalibreLibraryInfo: Decodable {
    let defaultLibrary: String

    enum CodingKeys: String, CodingKey { case defaultLibrary = "default_library" }
}

struct CalibreSearch: Decodable {
    let bookIDs: [Int]

    enum CodingKeys: String, CodingKey { case bookIDs = "book_ids" }
}

struct CalibreBook: Decodable {
    struct Format: Decodable {
        let size: Int64?
    }

    let title: String?
    let authors: [String]?
    let formats: [String]?
    let formatMetadata: [String: Format]?
    let timestamp: String?
    let pubdate: String?
    let lastModified: String?
    let cover: String?
    let comments: String?

    enum CodingKeys: String, CodingKey {
        case title, authors, formats, timestamp, pubdate, cover, comments
        case formatMetadata = "format_metadata"
        case lastModified = "last_modified"
    }
}
