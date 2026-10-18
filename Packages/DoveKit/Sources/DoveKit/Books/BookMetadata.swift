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
/// | Audible catalog (`api.audible.<tld>/1.0/catalog/products`) | none | audiobooks; the device's region's store and the US one. Undocumented but public (Audiobookshelf uses it) |
/// | Storytel (`storytel.com/api/search.action`) | none | books and audiobooks in its markets (Poland, the Nordics…): local editions under local titles. Unofficial |
/// | Google Books (`googleapis.com/books/v1/volumes`) | user's | the anonymous quota is shared and usually used up, so only with a key |
/// | Hardcover (`api.hardcover.app/v1/graphql`) | user's token | books and audiobooks |
///
/// The picker search asks every source at once and ranks the answers against the words typed; matching a
/// library item asks one source after another until one has the book.
public struct BookMetadata: Sendable {
    public enum Source: Sendable, Hashable {
        case openLibrary
        case appleBooks(country: String = "US")
        case appleAudiobooks(country: String = "US")
        /// `com`, `co.uk`, `de`…
        case audible(domain: String = "com")
        /// Storytel's `request_locale` (`pl`, `sv`…).
        case storytel(locale: String)
        case googleBooks
        case hardcover
    }

    /// Where the device is and the keys the user gave.
    public struct Configuration: Sendable, Hashable {
        /// ISO region (`PL`, `DE`): picks the Apple Books, Audible and Storytel stores.
        public var region: String?
        /// ISO language (`pl`): Storytel's market.
        public var language: String?
        public var googleBooksKey: String?
        public var hardcoverToken: String?

        public init(region: String? = nil, language: String? = nil, googleBooksKey: String? = nil, hardcoverToken: String? = nil) {
            self.region = region?.uppercased()
            self.language = language?.lowercased()
            self.googleBooksKey = googleBooksKey.flatMap { $0.isEmpty ? nil : $0 }
            self.hardcoverToken = hardcoverToken.flatMap { $0.isEmpty ? nil : $0 }
        }

        /// The device's region and language, with the given keys.
        public static func device(googleBooksKey: String? = nil, hardcoverToken: String? = nil) -> Configuration {
            Configuration(
                region: Locale.current.region?.identifier,
                language: Locale.current.language.languageCode?.identifier,
                googleBooksKey: googleBooksKey,
                hardcoverToken: hardcoverToken
            )
        }

        /// Audible's store for the region; nil where Audible has none (Poland, the Nordics…).
        var audibleDomain: String? {
            switch region {
            case "US": "com"
            case "GB", "IE": "co.uk"
            case "DE", "AT", "CH": "de"
            case "FR", "BE": "fr"
            case "IT": "it"
            case "ES": "es"
            case "CA": "ca"
            case "AU", "NZ": "com.au"
            case "IN": "in"
            case "JP": "co.jp"
            default: nil
            }
        }

        /// Storytel's market: the region's, else the language's (an English iPhone in Poland still wants Polish
        /// editions); nil outside its markets (its English results are poor).
        var storytelLocale: String? {
            let byRegion: [String: String] = [
                "PL": "pl", "SE": "sv", "NO": "no", "DK": "da", "FI": "fi", "IS": "is", "NL": "nl", "ES": "es", "TR": "tr", "BG": "bg",
            ]
            if let region, let locale = byRegion[region] { return locale }
            switch language {
            case "pl", "sv", "da", "fi", "is", "nl", "es", "tr", "bg": return language
            case "nb", "nn", "no": return "no"
            default: return nil
            }
        }

        /// Apple's stores to ask: the device's, then the US one.
        var appleCountries: [String] {
            guard let region, region != "US" else { return ["US"] }
            return [region, "US"]
        }
    }

    static let openLibraryURL = URL(string: "https://openlibrary.org/search.json")!
    static let iTunesURL = URL(string: "https://itunes.apple.com/search")!
    static let storytelURL = URL(string: "https://www.storytel.com/api/search.action")!
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

    /// Where to look for a format, best first.
    public func sources(for format: BookFormat) -> [Source] {
        let config = configuration
        var sources: [Source]
        switch format {
        case .ebook:
            sources = [.openLibrary]
            if config.googleBooksKey != nil { sources.append(.googleBooks) }
            if config.hardcoverToken != nil { sources.append(.hardcover) }
            sources += config.appleCountries.map { .appleBooks(country: $0) }
            if let locale = config.storytelLocale { sources.append(.storytel(locale: locale)) }
        case .audiobook:
            if let domain = config.audibleDomain, domain != "com" { sources = [.audible(domain: domain)] } else { sources = [] }
            sources.append(.audible())
            if let locale = config.storytelLocale { sources.append(.storytel(locale: locale)) }
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
        case .audible(let domain):
            let url = URL(string: "https://api.audible.\(domain)/1.0/catalog/products")!
            let page = try await get(AudiblePage.self, url, [
                "keywords": query,
                "num_results": String(Self.limit),
                "products_sort_by": "Relevance",
                "response_groups": "contributors,media,product_desc,product_attrs",
            ])
            return page.products.compactMap { $0.summary(domain: domain) }
        case .storytel(let locale):
            let page = try await get(StorytelPage.self, Self.storytelURL, ["q": query, "request_locale": locale])
            return page.books.compactMap { $0.summary(format: format) }.prefix(Self.limit).map { $0 }
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

    private func get<T: Decodable>(_ type: T.Type, _ url: URL, _ parameters: [String: String]) async throws -> T {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
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

// MARK: - Audible

struct AudiblePage: Decodable {
    var products: [Product]

    struct Product: Decodable {
        var asin: String
        var title: String?
        var subtitle: String?
        var authors: [Person]?
        var narrators: [Person]?
        var releaseDate: String?
        var productImages: [String: String]?
        var merchandisingSummary: String?

        struct Person: Decodable {
            var name: String
        }

        enum CodingKeys: String, CodingKey {
            case asin, title, subtitle, authors, narrators
            case releaseDate = "release_date"
            case productImages = "product_images"
            case merchandisingSummary = "merchandising_summary"
        }

        func summary(domain: String) -> BookSummary? {
            guard let title, !title.isEmpty else { return nil }
            // Translators are listed as authors ("Irmtraud Zimmermann-Göllheim - translator").
            let authors = (authors ?? []).map(\.name).filter { !$0.lowercased().hasSuffix(" - translator") }
            return BookSummary(
                id: "audible:\(asin)",
                title: BookMatcher.withoutEdition(title),
                authors: authors,
                year: releaseDate.flatMap { Int($0.prefix(4)) },
                cover: productImages?.sorted { (Int($0.key) ?? 0) > (Int($1.key) ?? 0) }.first.flatMap { URL(string: $0.value) },
                description: merchandisingSummary.map(ITunesPage.Result.plainText),
                link: URL(string: "https://www.audible.\(domain)/pd/\(asin)")
            )
        }
    }
}

// MARK: - Storytel

struct StorytelPage: Decodable {
    var books: [Entry]

    struct Entry: Decodable {
        var book: Book
        var abook: Format?
        var ebook: Format?
        var shareUrl: String?

        struct Book: Decodable {
            var id: Int
            var name: String
            var authors: [Person]?
            var largeCover: String?
            var largeCoverE: String?
            var latestReleaseDate: String?
        }

        struct Person: Decodable {
            var name: String
        }

        struct Format: Decodable {
            var description: String?
        }

        /// One entry may carry the audiobook, the ebook or both; only entries in the asked format count.
        func summary(format: BookFormat) -> BookSummary? {
            guard let edition = format == .audiobook ? abook : ebook else { return nil }
            let paths = format == .audiobook ? [book.largeCover, book.largeCoverE] : [book.largeCoverE, book.largeCover]
            let cover = paths.compactMap { $0 }.first { !$0.contains("nocover") }
            return BookSummary(
                id: "storytel:\(book.id)",
                title: book.name,
                authors: (book.authors ?? []).map(\.name),
                year: book.latestReleaseDate.flatMap { Int($0.prefix(4)) },
                cover: cover.flatMap { URL(string: "https://www.storytel.com" + $0) },
                description: edition.description,
                link: shareUrl.flatMap(URL.init(string:))
            )
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
