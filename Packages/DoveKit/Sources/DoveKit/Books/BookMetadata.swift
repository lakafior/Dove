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

/// Covers and titles for books and audiobooks. Metadata services, not content sources; the user brings any key.
///
/// | Source | Key | For |
/// |---|---|---|
/// | Open Library (`openlibrary.org/search.json`) | none | books (and audiobooks as a fallback) |
/// | Apple Books (iTunes Search, `media=ebook|audiobook`) | none | the US store and the device's region's store; about 20 calls a minute |
/// | Google Books (`googleapis.com/books/v1/volumes`) | user's | the anonymous quota is shared and usually used up, so only with a key |
/// | Hardcover (`api.hardcover.app/v1/graphql`) | user's token | books and audiobooks |
/// | The user's Audiobookshelf metadata providers (`BookProvider`) | the provider's, if any | whatever they cover: Storytel, lubimyczytac… |
///
/// Dove itself calls only official APIs: unofficial sources (Audible's catalog, Storytel, lubimyczytac, Goodreads)
/// come only as providers the user adds by URL, in Audiobookshelf's custom metadata provider format.
/// The picker search asks every source at once and ranks the answers against the words typed; matching a
/// library item asks one source after another until one has the book.
public struct BookMetadata: Sendable {
    public enum Source: Sendable, Hashable {
        case openLibrary
        case appleBooks(country: String = "US")
        case appleAudiobooks(country: String = "US")
        /// One of the user's Audiobookshelf metadata providers.
        case provider(BookProvider)
        case googleBooks
        case hardcover
    }

    /// Where the device is and the keys the user gave.
    public struct Configuration: Sendable, Hashable {
        /// ISO region (`PL`, `DE`): picks the Apple Books store.
        public var region: String?
        public var googleBooksKey: String?
        public var hardcoverToken: String?
        /// The user's Audiobookshelf metadata providers; only enabled ones are asked.
        public var providers: [BookProvider]

        public init(
            region: String? = nil,
            googleBooksKey: String? = nil,
            hardcoverToken: String? = nil,
            providers: [BookProvider] = []
        ) {
            self.region = region?.uppercased()
            self.googleBooksKey = googleBooksKey.flatMap { $0.isEmpty ? nil : $0 }
            self.hardcoverToken = hardcoverToken.flatMap { $0.isEmpty ? nil : $0 }
            self.providers = providers.filter(\.enabled)
        }

        /// The device's region, with the user's keys and providers.
        public static func device(
            googleBooksKey: String? = nil,
            hardcoverToken: String? = nil,
            providers: [BookProvider] = []
        ) -> Configuration {
            Configuration(
                region: Locale.current.region?.identifier,
                googleBooksKey: googleBooksKey,
                hardcoverToken: hardcoverToken,
                providers: providers
            )
        }

        /// Apple's stores to ask: the device's, then the US one.
        var appleCountries: [String] {
            guard let region, region != "US" else { return ["US"] }
            return [region, "US"]
        }
    }

    static let openLibraryURL = URL(string: "https://openlibrary.org/search.json")!
    static let iTunesURL = URL(string: "https://itunes.apple.com/search")!
    static let googleBooksURL = URL(string: "https://www.googleapis.com/books/v1/volumes")!
    static let hardcoverURL = URL(string: "https://api.hardcover.app/v1/graphql")!
    /// Open Library asks clients to say who they are.
    static let userAgent = "Dove (iOS; library covers)"
    static let limit = 10

    public let configuration: Configuration
    private let transport: any HTTPTransport

    public init(configuration: Configuration = Configuration(), transport: any HTTPTransport = URLSession.shared) {
        self.configuration = configuration
        self.transport = transport
    }

    /// Where to look for a format, best first. The user's providers come first: they were added for books the
    /// built-in sources miss.
    public func sources(for format: BookFormat) -> [Source] {
        let config = configuration
        var sources: [Source] = config.providers.map { .provider($0) }
        switch format {
        case .ebook:
            sources.append(.openLibrary)
            if config.googleBooksKey != nil { sources.append(.googleBooks) }
            if config.hardcoverToken != nil { sources.append(.hardcover) }
            sources += config.appleCountries.map { .appleBooks(country: $0) }
        case .audiobook:
            sources += config.appleCountries.map { .appleAudiobooks(country: $0) }
            if config.hardcoverToken != nil { sources.append(.hardcover) }
            sources.append(.openLibrary)
            if config.googleBooksKey != nil { sources.append(.googleBooks) }
        }
        return sources
    }

    /// The best fitting book from the first source that has one; nil when none fits. Throws only when every
    /// source failed (the library tries again on its next refresh).
    public func match(_ guess: BookGuess) async throws -> BookSummary? {
        var failure: (any Error)?
        var answered = false
        for source in sources(for: guess.format) {
            do {
                let results = try await search(guess.query, in: source, format: guess.format)
                answered = true
                if let best = BookMatcher.best(results, for: guess) { return best }
            } catch {
                failure = failure ?? error
            }
        }
        if !answered, let failure { throw failure }
        return nil
    }

    /// Every source's results for a format, at once: one entry per book (`BookSummary.unique`), the ones that
    /// fit the words best first. Throws only when every source failed.
    public func search(_ query: String, format: BookFormat) async throws -> [BookSummary] {
        let sources = sources(for: format)
        var answers: [Int: [BookSummary]] = [:]
        var failure: (any Error)?
        await withTaskGroup(of: (Int, Result<[BookSummary], any Error>).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    do { return (index, .success(try await self.search(query, in: source, format: format))) }
                    catch { return (index, .failure(error)) }
                }
            }
            for await (index, result) in group {
                switch result {
                case .success(let books): answers[index] = books
                case .failure(let error): failure = failure ?? error
                }
            }
        }
        if answers.isEmpty, let failure { throw failure }
        let books = BookSummary.unique(sources.indices.flatMap { answers[$0] ?? [] })
        return BookMatcher.rank(books, for: BookGuess(releaseName: query, format: format))
    }

    public func search(_ query: String, in source: Source, format: BookFormat = .ebook) async throws -> [BookSummary] {
        switch source {
        case .openLibrary:
            let page = try await get(OpenLibraryPage.self, Self.openLibraryURL, [
                "q": query,
                "fields": "key,title,author_name,first_publish_year,cover_i",
                "limit": String(Self.limit),
            ])
            return page.docs.compactMap(\.summary)
        case .appleBooks(let country), .appleAudiobooks(let country):
            let media = if case .appleBooks = source { "ebook" } else { "audiobook" }
            var parameters = ["term": query, "media": media, "entity": media, "limit": String(Self.limit)]
            if country != "US" { parameters["country"] = country }
            let page = try await get(ITunesPage.self, Self.iTunesURL, parameters)
            return page.results.compactMap(\.summary)
        case .provider(let provider):
            var headers: [String: String] = [:]
            if let key = provider.authorization, !key.isEmpty { headers["Authorization"] = key }
            // `format` is not in Audiobookshelf's spec: providers that know it (aio-abs-providers) answer one kind,
            // the rest ignore it; a match's `type`, when given, filters either way.
            let page = try await get(ProviderPage.self, provider.searchURL, [
                "query": query, "mediaType": "book", "format": format == .audiobook ? "audiobook" : "ebook",
            ], headers: headers)
            return page.matches.filter { $0.fits(format) }.prefix(Self.limit).compactMap { $0.summary(provider: provider) }
        case .googleBooks:
            guard let key = configuration.googleBooksKey else { return [] }
            let page = try await get(GoogleBooksPage.self, Self.googleBooksURL, [
                "q": query, "key": key, "maxResults": String(Self.limit), "printType": "books",
            ])
            return (page.items ?? []).compactMap(\.summary)
        case .hardcover:
            guard let token = configuration.hardcoverToken else { return [] }
            return try await hardcover(query, token: token)
        }
    }

    /// Checks a provider with one search: it must answer with Audiobookshelf's `matches` list.
    public func validate(_ provider: BookProvider) async throws {
        _ = try await search("dune", in: .provider(provider))
    }

    /// Checks a Google Books key with one search.
    public func validateGoogleBooks(key: String) async throws {
        _ = try await get(GoogleBooksPage.self, Self.googleBooksURL, ["q": "dune", "key": key, "maxResults": "1"])
    }

    /// Checks a Hardcover token (`me`).
    public func validateHardcover(token: String) async throws {
        let response = try await graphQL(HardcoverMe.self, query: "{ me { id } }", variables: [:], token: token)
        guard response.data?.me?.isEmpty == false else { throw BackendError.unauthorized }
    }

    // MARK: Requests

    private func get<T: Decodable>(
        _ type: T.Type,
        _ url: URL,
        _ parameters: [String: String],
        headers: [String: String] = [:]
    ) async throws -> T {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? [])
            + parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.send(request)
        if let error = response.backendError {
            // Apple answers its rate limit with 403; Google's key errors come as 400 with a message.
            if url == Self.googleBooksURL, let message = GoogleBooksError.message(in: data) {
                throw BackendError.api(message: message)
            }
            throw error == .unauthorized && url == Self.iTunesURL ? BackendError.rateLimited : error
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw BackendError.invalidResponse
        }
    }

    private func hardcover(_ query: String, token: String) async throws -> [BookSummary] {
        let response = try await graphQL(
            HardcoverSearch.self,
            query: "query Search($q: String!) { search(query: $q, query_type: \"Book\", per_page: \(Self.limit), page: 1) { results } }",
            variables: ["q": query],
            token: token
        )
        if let message = response.errors?.first?.message { throw BackendError.api(message: message) }
        return response.data?.search?.results?.hits?.compactMap(\.document.summary) ?? []
    }

    private func graphQL<T: Decodable>(_ type: T.Type, query: String, variables: [String: String], token: String) async throws -> T {
        var request = URLRequest(url: Self.hardcoverURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // Hardcover's settings page shows the token with its "Bearer " prefix; accept it either way.
        let bare = token.hasPrefix("Bearer ") ? String(token.dropFirst(7)) : token
        request.setValue("Bearer \(bare)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await transport.send(request)
        if let error = response.backendError { throw error }
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

// MARK: - Google Books

struct GoogleBooksPage: Decodable {
    var items: [Volume]?

    struct Volume: Decodable {
        var id: String
        var volumeInfo: Info

        struct Info: Decodable {
            var title: String?
            var subtitle: String?
            var authors: [String]?
            var publishedDate: String?
            var description: String?
            var imageLinks: [String: String]?
            var infoLink: String?
        }

        var summary: BookSummary? {
            guard let title = volumeInfo.title, !title.isEmpty else { return nil }
            let image = volumeInfo.imageLinks.flatMap { $0["thumbnail"] ?? $0["smallThumbnail"] }
            return BookSummary(
                id: "gb:\(id)",
                title: title,
                authors: volumeInfo.authors ?? [],
                year: volumeInfo.publishedDate.flatMap { Int($0.prefix(4)) },
                // Google sends http links and a small zoom; https and no curl give the plain cover.
                cover: image.flatMap {
                    URL(string: $0.replacingOccurrences(of: "http://", with: "https://").replacingOccurrences(of: "&edge=curl", with: ""))
                },
                description: volumeInfo.description.map(ITunesPage.Result.plainText),
                link: volumeInfo.infoLink.flatMap(URL.init(string:))
            )
        }
    }
}

enum GoogleBooksError {
    /// `{"error":{"message":"API key not valid. Please pass a valid API key."}}`
    static func message(in data: Data) -> String? {
        struct Body: Decodable {
            struct Inner: Decodable { var message: String }
            var error: Inner
        }
        return (try? JSONDecoder().decode(Body.self, from: data))?.error.message
    }
}

// MARK: - Hardcover

struct HardcoverSearch: Decodable {
    var data: DataBody?
    var errors: [HardcoverError]?

    struct DataBody: Decodable {
        var search: Search?
    }

    struct Search: Decodable {
        var results: Results?
    }

    /// Typesense hits, passed through as JSON.
    struct Results: Decodable {
        var hits: [Hit]?
    }

    struct Hit: Decodable {
        var document: Document
    }

    struct Document: Decodable {
        var id: String
        var title: String?
        var authorNames: [String]?
        var releaseYear: Int?
        var description: String?
        var image: Image?
        var slug: String?

        struct Image: Decodable {
            var url: String?
        }

        enum CodingKeys: String, CodingKey {
            case id, title, description, image, slug
            case authorNames = "author_names"
            case releaseYear = "release_year"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Typesense IDs are strings; some documents carry numbers.
            if let text = try? container.decode(String.self, forKey: .id) {
                id = text
            } else {
                id = String(try container.decode(Int.self, forKey: .id))
            }
            title = try container.decodeIfPresent(String.self, forKey: .title)
            authorNames = try container.decodeIfPresent([String].self, forKey: .authorNames)
            releaseYear = try? container.decodeIfPresent(Int.self, forKey: .releaseYear)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            image = try? container.decodeIfPresent(Image.self, forKey: .image)
            slug = try container.decodeIfPresent(String.self, forKey: .slug)
        }

        var summary: BookSummary? {
            guard let title, !title.isEmpty else { return nil }
            return BookSummary(
                id: "hardcover:\(id)",
                title: title,
                authors: authorNames ?? [],
                year: releaseYear,
                cover: image?.url.flatMap(URL.init(string:)),
                description: description,
                link: slug.flatMap { URL(string: "https://hardcover.app/books/\($0)") }
            )
        }
    }
}

struct HardcoverError: Decodable {
    var message: String
}

struct HardcoverMe: Decodable {
    var data: DataBody?

    struct DataBody: Decodable {
        var me: [Me]?
    }

    struct Me: Decodable {
        var id: Int
    }
}

// MARK: - Audiobookshelf providers

/// Audiobookshelf's custom metadata provider answer (`GET /search` → `{"matches": [...]}`).
struct ProviderPage: Decodable {
    var matches: [Match]

    struct Match: Decodable {
        var title: String?
        var subtitle: String?
        /// Comma-separated when there are several.
        var author: String?
        var publishedYear: String?
        var description: String?
        var cover: String?
        var isbn: String?
        var asin: String?
        /// `audiobook` or `book` from providers that tell them apart (aio-abs-providers); absent elsewhere.
        var type: String?

        enum CodingKeys: String, CodingKey {
            case title, subtitle, author, publishedYear, description, cover, isbn, asin, type
        }

        /// Matches without a type fit both formats.
        func fits(_ format: BookFormat) -> Bool {
            guard let type = type?.lowercased(), !type.isEmpty else { return true }
            return (type == "audiobook") == (format == .audiobook)
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            subtitle = try? container.decodeIfPresent(String.self, forKey: .subtitle)
            author = try? container.decodeIfPresent(String.self, forKey: .author)
            // The spec says string; some providers send a number.
            publishedYear = (try? container.decodeIfPresent(String.self, forKey: .publishedYear))
                ?? (try? container.decodeIfPresent(Int.self, forKey: .publishedYear)).map(String.init)
            description = try? container.decodeIfPresent(String.self, forKey: .description)
            cover = try? container.decodeIfPresent(String.self, forKey: .cover)
            isbn = try? container.decodeIfPresent(String.self, forKey: .isbn)
            asin = try? container.decodeIfPresent(String.self, forKey: .asin)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
        }

        func summary(provider: BookProvider) -> BookSummary? {
            guard let title, !title.isEmpty else { return nil }
            let authors = (author ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let key = asin ?? isbn ?? MediaGuess.normalize((authors.first ?? "") + title)
            return BookSummary(
                id: "provider:\(provider.id):\(key)",
                title: title,
                authors: authors,
                year: publishedYear.flatMap { Int($0.prefix(4)) },
                cover: cover.flatMap(URL.init(string:)),
                description: description.map(ITunesPage.Result.plainText)
            )
        }
    }
}
