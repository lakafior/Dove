import Foundation

/// A book or audiobook as a metadata service describes it: real title, authors, cover.
public struct BookSummary: Identifiable, Sendable, Hashable, Codable {
    /// `ol:OL21745884W` (Open Library work) or `itunes:1565808256` (Apple Books).
    public let id: String
    public var title: String
    public var authors: [String]
    public var year: Int?
    public var cover: URL?
    /// Plain text.
    public var description: String?
    /// The service's page for it.
    public var link: URL?

    public init(
        id: String,
        title: String,
        authors: [String] = [],
        year: Int? = nil,
        cover: URL? = nil,
        description: String? = nil,
        link: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.year = year
        self.cover = cover
        self.description = description
        self.link = link
    }
}

/// Covers and titles for books and audiobooks from services that need no key:
/// - Open Library (`openlibrary.org/search.json`): books; covers from `covers.openlibrary.org`.
/// - iTunes Search (`itunes.apple.com/search`, `media=ebook|audiobook`): Apple Books and audiobooks, square
///   audiobook artwork (`artworkUrl100` scaled to 600 px). Apple allows roughly 20 calls a minute.
///
/// Books ask Open Library first, audiobooks the audiobook store; the other source answers when the first has
/// nothing fitting. These are metadata services, not content sources.
public struct BookMetadata: Sendable {
    public enum Source: Sendable, CaseIterable {
        case openLibrary, appleBooks, appleAudiobooks
    }

    static let openLibraryURL = URL(string: "https://openlibrary.org/search.json")!
    static let iTunesURL = URL(string: "https://itunes.apple.com/search")!
    /// Open Library asks clients to say who they are.
    static let userAgent = "Dove (iOS; library covers)"
    static let limit = 10

    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSession.shared) {
        self.transport = transport
    }

    /// Where to look for a format, best first.
    public static func sources(for format: BookFormat) -> [Source] {
        switch format {
        case .ebook: [.openLibrary, .appleBooks]
        case .audiobook: [.appleAudiobooks, .openLibrary]
        }
    }

    /// The best fitting book from the first source that has one; nil when none fits.
    public func match(_ guess: BookGuess) async throws -> BookSummary? {
        for source in Self.sources(for: guess.format) {
            if let best = BookMatcher.best(try await search(guess.query, in: source), for: guess) { return best }
        }
        return nil
    }

    /// Every source's results for a format, best source first, for the user to pick from.
    /// Throws only when every source failed.
    public func search(_ query: String, format: BookFormat) async throws -> [BookSummary] {
        var results: [BookSummary] = []
        var failure: (any Error)?
        for source in Self.sources(for: format) {
            do { results += try await search(query, in: source) } catch { failure = failure ?? error }
        }
        if results.isEmpty, let failure { throw failure }
        return results
    }

    public func search(_ query: String, in source: Source) async throws -> [BookSummary] {
        switch source {
        case .openLibrary:
            let page = try await get(OpenLibraryPage.self, Self.openLibraryURL, [
                "q": query,
                "fields": "key,title,author_name,first_publish_year,cover_i",
                "limit": String(Self.limit),
            ])
            return page.docs.compactMap(\.summary)
        case .appleBooks, .appleAudiobooks:
            let media = source == .appleBooks ? "ebook" : "audiobook"
            let page = try await get(ITunesPage.self, Self.iTunesURL, [
                "term": query,
                "media": media,
                "entity": media,
                "limit": String(Self.limit),
            ])
            return page.results.compactMap(\.summary)
        }
    }

    private func get<T: Decodable>(_ type: T.Type, _ url: URL, _ parameters: [String: String]) async throws -> T {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.send(request)
        if let error = response.backendError {
            // Apple answers its rate limit with 403; nothing here has a key that could be wrong.
            throw error == .unauthorized ? BackendError.rateLimited : error
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw BackendError.invalidResponse
        }
    }
}

// MARK: - Open Library

struct OpenLibraryPage: Decodable {
    var docs: [Doc]

    struct Doc: Decodable {
        var key: String
        var title: String?
        var authorName: [String]?
        var firstPublishYear: Int?
        var coverID: Int?

        enum CodingKeys: String, CodingKey {
            case key, title
            case authorName = "author_name"
            case firstPublishYear = "first_publish_year"
            case coverID = "cover_i"
        }

        var summary: BookSummary? {
            guard let title, !title.isEmpty else { return nil }
            let work = key.split(separator: "/").last.map(String.init) ?? key
            return BookSummary(
                id: "ol:\(work)",
                title: title,
                authors: authorName ?? [],
                year: firstPublishYear,
                cover: coverID.flatMap { URL(string: "https://covers.openlibrary.org/b/id/\($0)-L.jpg") },
                link: URL(string: "https://openlibrary.org" + key)
            )
        }
    }
}

// MARK: - iTunes Search

struct ITunesPage: Decodable {
    var results: [Result]

    /// Audiobooks are collections (`collectionId`, `collectionName`), ebooks tracks (`trackId`, `trackName`).
    struct Result: Decodable {
        var collectionId: Int?
        var collectionName: String?
        var collectionViewUrl: URL?
        var trackId: Int?
        var trackName: String?
        var trackViewUrl: URL?
        var artistName: String?
        var artworkUrl100: String?
        var releaseDate: String?
        var description: String?

        var summary: BookSummary? {
            guard let id = collectionId ?? trackId, let name = collectionName ?? trackName else { return nil }
            return BookSummary(
                id: "itunes:\(id)",
                title: BookMatcher.withoutEdition(name),
                authors: artistName.map { [$0] } ?? [],
                year: releaseDate.flatMap { Int($0.prefix(4)) },
                cover: artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "/100x100bb.", with: "/600x600bb.")) },
                description: description.map(Self.plainText),
                link: collectionViewUrl ?? trackViewUrl
            )
        }

        /// Apple's descriptions are HTML (`<b>`, `<br />`, `&amp;`).
        static func plainText(_ html: String) -> String {
            html.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
