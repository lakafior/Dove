import Foundation

/// The user's Audiobookshelf server: a place the user keeps audiobooks (and ebooks), listed like a service and
/// sent audiobooks to. Each library item is an item (`abs:<id>`), each of its files a file (by `ino`), and the item
/// carries the server's own metadata (`LibraryItem.book`), so the Library shows it without a lookup.
///
/// Like every place it does three things: lists what is there, says what is already held (the Library's "In
/// library" marks), takes files (`upload`). Playback, progress, editing and deleting stay in Audiobookshelf's own
/// apps.
///
/// API (`advplyr/audiobookshelf`, `server/routers/ApiRouter.js`): `GET api/me` (the account and its permissions),
/// `GET api/libraries`, `GET api/libraries/<id>/items?minified=1` (pages), `GET api/items/<id>?expanded=1` (files),
/// `GET api/items/<id>/file/<ino>/download`, `GET api/items/<id>/cover`, `POST api/filesystem/pathexists` and
/// `POST api/upload` (multipart). Every request carries an API key (Settings › API Keys, server 2.26+) or a user's
/// token as `Authorization: Bearer`.
public struct AudiobookshelfBackend: LibraryBackend {
    public let id: BackendID = .audiobookshelf
    let baseURL: URL
    let token: String
    /// The library uploads go to; nil takes the first audiobook library.
    let libraryID: String?
    private let transport: any HTTPTransport

    static let pageSize = 500
    static let itemPrefix = "abs:"

    public init(baseURL: URL, token: String, libraryID: String? = nil, transport: any HTTPTransport = URLSession.shared) {
        self.baseURL = baseURL
        self.token = token
        self.libraryID = libraryID.flatMap { $0.isEmpty ? nil : $0 }
        self.transport = transport
    }

    public var supportedSources: Set<SourceKind> { [] }

    public func validateCredentials() async throws {
        let account = try await account()
        guard account.libraries.contains(where: \.isBooks) else {
            throw BackendError.api(message: "Audiobookshelf has no audiobook library this account can see.")
        }
    }

    public func add(_ source: Source) async throws -> LibraryItem.ID {
        throw BackendError.unsupportedSource(source.kind)
    }

    public func delete(_ itemID: LibraryItem.ID) async throws {
        throw BackendError.api(message: "Dove does not delete from Audiobookshelf. Remove it in Audiobookshelf itself.")
    }

    // MARK: - Account

    public struct Library: Sendable, Hashable, Identifiable, Decodable {
        public struct Folder: Sendable, Hashable, Decodable {
            public let id: String
            public let fullPath: String
        }

        public let id: String
        public let name: String
        public let mediaType: String
        public let folders: [Folder]

        /// Audiobooks and ebooks; podcast libraries are left out.
        public var isBooks: Bool { mediaType == "book" }
    }

    /// Who the key belongs to and what it may do: listing needs nothing, downloading needs "Can download",
    /// sending needs "Can upload" (off for new users).
    public struct Account: Sendable, Equatable {
        public let username: String
        public let canUpload: Bool
        public let canDownload: Bool
        public let libraries: [Library]

        /// Audiobook libraries the account sees.
        public var bookLibraries: [Library] { libraries.filter(\.isBooks) }
    }

    public func account() async throws -> Account {
        let me: AudiobookshelfUser = try await get("api/me")
        let libraries: AudiobookshelfLibraries = try await get("api/libraries")
        // The server's own rule (`User.canUpload`, `canDownload`): the permission flag alone, whatever the type.
        return Account(
            username: me.username ?? "",
            canUpload: me.permissions?.upload == true,
            canDownload: me.permissions?.download == true,
            libraries: libraries.libraries
        )
    }

    // MARK: - Listing

    public func items() async throws -> [LibraryItem] {
        let libraries: AudiobookshelfLibraries = try await get("api/libraries")
        var items: [LibraryItem] = []
        for library in libraries.libraries where library.isBooks {
            var page = 0
            while true {
                let answer: AudiobookshelfPage = try await get("api/libraries/\(library.id)/items", [
                    URLQueryItem(name: "minified", value: "1"),
                    URLQueryItem(name: "limit", value: String(Self.pageSize)),
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "sort", value: "addedAt"),
                    URLQueryItem(name: "desc", value: "1"),
                ])
                items += answer.results.filter { $0.isMissing != true }.map(item)
                page += 1
                if answer.results.count < Self.pageSize || page * Self.pageSize >= (answer.total ?? 0) { break }
            }
        }
        return items
    }

    /// One item with its files (the list leaves them out).
    public func item(_ itemID: LibraryItem.ID) async throws -> LibraryItem {
        guard let id = Self.serverID(itemID) else { throw BackendError.notFound }
        let detail: AudiobookshelfItem = try await get("api/items/\(id)", [URLQueryItem(name: "expanded", value: "1")])
        return item(detail)
    }

    func item(_ entry: AudiobookshelfItem) -> LibraryItem {
        let metadata = entry.media.metadata
        let title = metadata.title ?? "Untitled"
        let authors = Self.authors(metadata.authorName)
        let files = (entry.libraryFiles ?? []).filter { $0.fileType != "metadata" }.map { file in
            LibraryFile(id: file.ino, name: file.metadata.relPath ?? file.metadata.filename ?? file.ino, size: file.metadata.size.map { Int64($0) })
        }
        let hasAudio = (entry.media.numTracks ?? entry.media.numAudioFiles ?? 0) > 0
            || entry.libraryFiles?.contains { $0.fileType == "audio" } == true
        let hasEbook = entry.media.ebookFormat != nil || entry.libraryFiles?.contains { $0.fileType == "ebook" } == true
        return LibraryItem(
            id: Self.itemPrefix + entry.id,
            backend: id,
            name: authors.first.map { LibraryFolderLayout.itemName(author: $0, title: title) } ?? title,
            size: (entry.size ?? entry.media.size).map { Int64($0) },
            status: .ready,
            files: files,
            addedAt: entry.addedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            kindHint: !hasAudio && hasEbook ? .books : .audiobooks,
            book: BookSummary(
                id: Self.itemPrefix + entry.id,
                title: title,
                authors: authors,
                year: metadata.publishedYear.flatMap { Int($0.prefix(4)) },
                cover: entry.media.coverPath == nil ? nil : Self.coverURL(itemID: entry.id, version: entry.updatedAt),
                description: metadata.description.flatMap(CalibreBackend.plainText)
            )
        )
    }

    // MARK: - Files and covers

    public func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest {
        guard let id = Self.serverID(itemID) else { throw BackendError.notFound }
        return request("api/items/\(id)/file/\(fileID)/download")
    }

    /// `audiobookshelf://cover/<item id>?v=<updated>`: without the server's address or the key, so the image cache
    /// keys one copy per cover and a new cover gets a new URL. `ImageCache` asks `coverRequest` for the real one.
    public static let coverScheme = "audiobookshelf"

    static func coverURL(itemID: String, version: Double?) -> URL? {
        var components = URLComponents()
        components.scheme = coverScheme
        components.host = "cover"
        components.path = "/\(itemID)"
        if let version { components.queryItems = [URLQueryItem(name: "v", value: String(Int(version)))] }
        return components.url
    }

    public func coverRequest(for url: URL) async throws -> URLRequest {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard url.scheme == Self.coverScheme, url.host == "cover", parts.count == 1 else { throw BackendError.notFound }
        return request("api/items/\(parts[0])/cover", [
            URLQueryItem(name: "width", value: "400"),
            URLQueryItem(name: "format", value: "jpeg"),
        ])
    }

    // MARK: - Sending

    /// Where an upload lands: the library and its first folder.
    public func uploadTarget() async throws -> (library: Library, folder: Library.Folder) {
        let account = try await account()
        guard account.canUpload else {
            throw BackendError.api(message: "This Audiobookshelf account may not upload. Turn on \"Can Upload\" for \(account.username.isEmpty ? "it" : account.username) in Audiobookshelf › Settings › Users.")
        }
        let books = account.bookLibraries
        guard let library = libraryID.flatMap({ id in books.first { $0.id == id } }) ?? books.first,
              let folder = library.folders.first
        else { throw BackendError.api(message: "Audiobookshelf has no audiobook library with a folder to upload to.") }
        return (library, folder)
    }

    /// The folder the server would make (`<folder>/<author>/<series>/<title>`, as `MiscController.handleUpload`
    /// does), relative to the library folder.
    static func uploadDirectory(title: String, author: String?, series: String?) -> String {
        [author, series, title].compactMap { $0 }.map(sanitized).filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// The server refuses an upload into a folder that exists; this says so before anything is sent.
    public func pathExists(title: String, author: String?, series: String?, folder: Library.Folder) async throws -> (exists: Bool, title: String?) {
        let body = try JSONEncoder().encode(AudiobookshelfPathQuery(
            directory: Self.uploadDirectory(title: title, author: author, series: series),
            folderPath: folder.fullPath
        ))
        let answer: AudiobookshelfPathAnswer = try await perform("api/filesystem/pathexists", method: "POST", body: body)
        return (answer.exists, answer.libraryItemTitle)
    }

    /// Sends a book's files (`POST api/upload`, the web app's upload page): the server files them under
    /// Author/Series/Title in the library's folder and scans them. The body is written to a temporary file and
    /// streamed (an audiobook can be gigabytes), with progress from 0 to 1.
    public func upload(
        files: [URL],
        title: String,
        author: String?,
        series: String? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let target = try await uploadTarget()
        if try await pathExists(title: title, author: author, series: series, folder: target.folder).exists {
            throw BackendError.api(message: "Audiobookshelf already has a folder for \(title). Remove or rename it there to send it again.")
        }
        let body = FileManager.default.temporaryDirectory.appending(path: "abs-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: body) }
        let boundary = try AudiobookshelfUpload.writeBody(
            to: body, files: files, title: title, author: author, series: series,
            libraryID: target.library.id, folderID: target.folder.id
        )
        var request = request("api/upload")
        request.httpMethod = "POST"
        // An idle limit, not a total one: the server moves the files only after it has them all.
        request.timeoutInterval = 900
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.upload(for: request, fromFile: body, delegate: UploadProgress(report: progress))
        } catch let error as URLError {
            throw BackendError.api(message: "Audiobookshelf did not take the upload: \(CalibreBackend.reason(error))")
        }
        guard let http = response as? HTTPURLResponse else { throw BackendError.invalidResponse }
        if let error = Self.error(status: http.statusCode, body: data) { throw error }
    }

    // MARK: - HTTP

    func request(_ path: String, _ query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        try await perform(path, query)
    }

    private func perform<T: Decodable>(_ path: String, _ query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) async throws -> T {
        var request = request(path, query)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError {
            throw BackendError.api(message: "Audiobookshelf did not answer: \(CalibreBackend.reason(error))")
        }
        if let error = Self.error(status: response.statusCode, body: data) { throw error }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BackendError.invalidResponse
        }
    }

    /// Audiobookshelf answers errors as plain text ("Unauthorized", "Not found").
    static func error(status: Int, body: Data) -> BackendError? {
        switch status {
        case 200..<300:
            return nil
        case 401:
            return .api(message: "Audiobookshelf refused the API key. Make a new one in Audiobookshelf › Settings › API Keys.")
        case 403:
            return .api(message: "Audiobookshelf refused: this account may not do that (check its permissions in Settings › Users).")
        case 404:
            return .notFound
        default:
            let text = String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .api(message: "Audiobookshelf answered \(status)" + (text.isEmpty || text.hasPrefix("<") ? "." : ": \(text)"))
        }
    }

    // MARK: - Parsing

    static func serverID(_ itemID: LibraryItem.ID) -> String? {
        guard itemID.hasPrefix(itemPrefix), itemID.count > itemPrefix.count else { return nil }
        return String(itemID.dropFirst(itemPrefix.count))
    }

    /// `authorName` is "A, B" (the list joins with commas).
    static func authors(_ text: String?) -> [String] {
        (text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// What the server's `sanitizeFilename` leaves of a folder name, near enough for `pathexists`.
    static func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: "[/\\\\?<>:*|\"]", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
    }
}

/// The multipart body of `POST api/upload`, written to a file.
enum AudiobookshelfUpload {
    /// Fields `title`, `author`, `series`, `library`, `folder`, then the files under `0`, `1`, … Returns the
    /// boundary.
    static func writeBody(
        to body: URL,
        files: [URL],
        title: String,
        author: String?,
        series: String?,
        libraryID: String,
        folderID: String
    ) throws -> String {
        let boundary = "Dove-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: body.path, contents: nil)
        let output = try FileHandle(forWritingTo: body)
        defer { try? output.close() }
        func field(_ name: String, _ value: String) -> Data {
            Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        try output.write(contentsOf: field("title", title))
        if let author { try output.write(contentsOf: field("author", author)) }
        if let series { try output.write(contentsOf: field("series", series)) }
        try output.write(contentsOf: field("library", libraryID))
        try output.write(contentsOf: field("folder", folderID))
        let names = uploadNames(for: files)
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            // A quote or a line break would break the header.
            let name = names[index].replacingOccurrences(of: "\"", with: "'")
                .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(index)\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data("\r\n".utf8))
        }
        try output.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
        return boundary
    }

    /// The server puts every file flat in the book's folder under its own name, so `CD1/01.mp3` and `CD2/01.mp3`
    /// would overwrite each other. When names repeat, each file in a subfolder gets the folder as a prefix
    /// (`CD1 - 01.mp3`), all of them so the discs keep their order; what still repeats gets a number.
    static func uploadNames(for files: [URL]) -> [String] {
        let plain = files.map(\.lastPathComponent)
        guard Set(plain.map { $0.lowercased() }).count < plain.count else { return plain }
        let parents = files.map { $0.deletingLastPathComponent().standardizedFileURL.path }
        let split = parents.map { $0.split(separator: "/", omittingEmptySubsequences: false) }
        var common = split.first ?? []
        for components in split.dropFirst() {
            common = Array(zip(common, components).prefix { $0 == $1 }.map(\.0))
        }
        let base = common.joined(separator: "/")
        var used: Set<String> = []
        return zip(files, parents).map { file, parent in
            var name = file.lastPathComponent
            if parent != base, parent.hasPrefix(base + "/") {
                let relative = parent.dropFirst(base.count + 1).replacingOccurrences(of: "/", with: " - ")
                name = "\(relative) - \(name)"
            }
            var candidate = name
            var counter = 2
            while used.contains(candidate.lowercased()) {
                let ext = (name as NSString).pathExtension
                let stem = (name as NSString).deletingPathExtension
                candidate = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
                counter += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }
}

/// Upload progress from `didSendBodyData`.
private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Double) -> Void

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

// MARK: - Wire types

struct AudiobookshelfUser: Decodable {
    struct Permissions: Decodable {
        let download: Bool?
        let upload: Bool?
    }

    let username: String?
    let type: String?
    let permissions: Permissions?
}

struct AudiobookshelfLibraries: Decodable {
    let libraries: [AudiobookshelfBackend.Library]
}

struct AudiobookshelfPage: Decodable {
    let results: [AudiobookshelfItem]
    let total: Int?
}

struct AudiobookshelfItem: Decodable {
    struct Media: Decodable {
        struct Metadata: Decodable {
            let title: String?
            let authorName: String?
            let publishedYear: String?
            let description: String?
        }

        let metadata: Metadata
        let coverPath: String?
        let numTracks: Int?
        let numAudioFiles: Int?
        let ebookFormat: String?
        let size: Double?
    }

    struct File: Decodable {
        struct Metadata: Decodable {
            let filename: String?
            let relPath: String?
            let size: Double?
        }

        let ino: String
        let metadata: Metadata
        let fileType: String?
    }

    let id: String
    let media: Media
    let size: Double?
    let addedAt: Double?
    let updatedAt: Double?
    let isMissing: Bool?
    let libraryFiles: [File]?
}

struct AudiobookshelfPathQuery: Encodable {
    let directory: String
    let folderPath: String
}

struct AudiobookshelfPathAnswer: Decodable {
    let exists: Bool
    let libraryItemTitle: String?
}
