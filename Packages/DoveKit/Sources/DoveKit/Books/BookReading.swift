import Foundation

/// Where "Read" sends an ebook. Apple Books takes EPUB and PDF; Send to Kindle (e-mail) takes EPUB, PDF and DOCX,
/// up to 50 MB. Neither takes MOBI or AZW3 (Amazon dropped MOBI from Send to Kindle in 2022).
public enum ReadingTarget: String, Codable, Sendable, CaseIterable, Identifiable {
    case appleBooks, kindle

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appleBooks: "Apple Books"
        case .kindle: "Kindle"
        }
    }

    /// Extensions the target takes, best first. EPUB reflows on any screen; PDF keeps its pages.
    public var formats: [String] {
        switch self {
        case .appleBooks: ["epub", "pdf"]
        case .kindle: ["epub", "pdf", "docx"]
        }
    }

    /// Amazon's limit for one Send to Kindle e-mail.
    public static let kindleMailLimit: Int64 = 50 * 1_000_000

    public var sizeLimit: Int64? { self == .kindle ? Self.kindleMailLimit : nil }
}

/// Picks the file "Read" sends from a book's releases: releases often carry the same book as EPUB, MOBI, AZW3 and
/// PDF side by side, plus a cover and an `.nfo`.
public enum BookFiles {
    /// Ebook formats, best first: what "Share" offers when no target takes the book.
    public static let ebookFormats = ["epub", "pdf", "azw3", "mobi", "azw", "fb2", "djvu", "docx", "cbz", "cbr"]

    public enum Refusal: Error, Sendable, Equatable {
        /// Nothing in the releases looks like an ebook (or the files are not listed yet).
        case noBookFile
        /// Only formats the target does not take, uppercased: `["AZW3", "MOBI"]`.
        case unsupported(formats: [String])
        /// The only usable file is over the Send to Kindle limit.
        case tooLarge(size: Int64)

        public func message(for target: ReadingTarget) -> String {
            switch self {
            case .noBookFile:
                return "No ebook file in this book's releases."
            case .unsupported(let formats):
                let list = ListFormatter.localizedString(byJoining: formats)
                return "\(target.displayName) does not take \(list). Use Share to open it in another reader."
            case .tooLarge(let size):
                let limit = ReadingTarget.kindleMailLimit.formatted(.byteCount(style: .file))
                return "The file is \(size.formatted(.byteCount(style: .file))); Send to Kindle takes up to \(limit)."
            }
        }
    }

    public struct Pick: Sendable, Hashable {
        public let item: LibraryItem
        public let file: LibraryFile
    }

    /// The best file for the target across the releases: the best format wins, then the earlier release (callers
    /// pass ready releases in their own order). Files over the target's size limit are skipped.
    public static func pick(from items: [LibraryItem], for target: ReadingTarget) -> Result<Pick, Refusal> {
        pick(from: items, formats: target.formats, sizeLimit: target.sizeLimit)
    }

    /// The best ebook file in any format, for the share sheet.
    public static func pickAny(from items: [LibraryItem]) -> Pick? {
        try? pick(from: items, formats: ebookFormats, sizeLimit: nil).get()
    }

    private static func pick(from items: [LibraryItem], formats: [String], sizeLimit: Int64?) -> Result<Pick, Refusal> {
        var best: (rank: Int, pick: Pick)?
        var tooLarge: Int64?
        var others: Set<String> = []
        for item in items {
            for file in item.files where !FileKind.isSample(file.name) {
                let ext = format(of: file.name)
                guard let rank = formats.firstIndex(of: ext) else {
                    if ebookFormats.contains(ext) { others.insert(ext.uppercased()) }
                    continue
                }
                if let sizeLimit, let size = file.size, size > sizeLimit {
                    tooLarge = min(tooLarge ?? size, size)
                    continue
                }
                if best == nil || rank < best!.rank {
                    best = (rank, Pick(item: item, file: file))
                }
            }
        }
        if let best { return .success(best.pick) }
        if let tooLarge { return .failure(.tooLarge(size: tooLarge)) }
        if !others.isEmpty { return .failure(.unsupported(formats: others.sorted())) }
        return .failure(.noBookFile)
    }

    public static func format(of name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    /// For the mail attachment.
    public static func mimeType(of name: String) -> String {
        switch format(of: name) {
        case "epub": "application/epub+zip"
        case "pdf": "application/pdf"
        case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        default: "application/octet-stream"
        }
    }

    /// A plausible e-mail address: something@domain.tld, no spaces. Amazon checks the rest.
    public static func isValidAddress(_ address: String) -> Bool {
        let address = address.trimmingCharacters(in: .whitespaces)
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !address.contains(" ") else { return false }
        let domain = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return domain.count >= 2 && domain.allSatisfy { !$0.isEmpty }
    }
}

/// Book files fetched for "Read" (Caches/Dove/Books/<service>/<item>/<file name>): the reader gets the file under its
/// own name, and a second Read does not download it again. iOS may clear it when space runs low.
public struct BookFileCache: Sendable {
    public let directory: URL

    public init(directory: URL = .cachesDirectory.appending(path: "Dove/Books")) {
        self.directory = directory
    }

    /// Item IDs are opaque (`torrent:123`, `link:https://…`), so they are reduced to safe path characters.
    public func url(for pick: BookFiles.Pick) -> URL {
        directory
            .appending(path: pick.item.backend.rawValue)
            .appending(path: Self.safe(pick.item.id))
            .appending(path: Self.safe((pick.file.name as NSString).lastPathComponent))
    }

    public func cached(_ pick: BookFiles.Pick) -> URL? {
        let url = url(for: pick)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Downloads the file once; later calls return the copy on disk.
    public func fetch(_ pick: BookFiles.Pick, request: @Sendable () async throws -> URLRequest) async throws -> URL {
        if let cached = cached(pick) { return cached }
        let (temporary, response) = try await URLSession.shared.download(for: try await request())
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw BackendError.api(message: "The service answered \(http.statusCode) for \(pick.file.name).")
        }
        let destination = url(for: pick)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    public func size() -> Int64 {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }
            .reduce(0) { $0 + Int64($1) }
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func safe(_ component: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-()[]"))
        let cleaned = String(component.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "_" : String(cleaned.prefix(200))
    }
}
