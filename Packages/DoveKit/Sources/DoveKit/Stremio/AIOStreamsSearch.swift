import Foundation

/// AIOStreams Search API: the same results as its Stremio `/stream` route, but structured
/// (`infoHash`, `fileIdx`, `nzbUrl`, `service`, `cached`, `folderSize`, `parsedFile`…).
/// Docs: https://github.com/Viren070/AIOStreams/blob/main/packages/docs/content/docs/apis/search.mdx
///
/// `GET {origin}/api/v1/search?type=…&id=…` with `Authorization: Basic base64(uuid:password)`.
public struct AIOStreamsSearch: Sendable {
    public let origin: URL
    public let uuid: String
    private let password: String
    private let transport: any HTTPTransport

    public init(origin: URL, uuid: String, password: String, transport: any HTTPTransport = URLSession.shared) {
        self.origin = origin
        self.uuid = uuid
        self.password = password
        self.transport = transport
    }

    /// Recognises an AIOStreams manifest URL (`{origin}/stremio/{uuid}/{config}/manifest.json`) and returns its parts.
    public static func instance(from manifestURL: URL) -> (origin: URL, uuid: String)? {
        let parts = manifestURL.pathComponents.filter { $0 != "/" }
        guard let index = parts.firstIndex(of: "stremio"),
              parts.count > index + 1,
              parts.last == "manifest.json",
              UUID(uuidString: parts[index + 1]) != nil,
              var components = URLComponents(url: manifestURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.path = ""
        components.query = nil
        guard let origin = components.url else { return nil }
        return (origin, parts[index + 1])
    }

    public struct Results: Sendable {
        public let candidates: [StreamCandidate]
        /// Per-source failures reported by AIOStreams (e.g. an expired key in one of its services).
        public let sourceErrors: [String]
    }

    public func search(type: MediaType, id: String) async throws -> Results {
        var components = URLComponents(url: origin.appending(path: "api/v1/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "type", value: type.rawValue), URLQueryItem(name: "id", value: id)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 60
        let credentials = Data("\(uuid):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await transport.send(request)
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        guard let envelope else { throw response.backendError ?? BackendError.invalidResponse }
        guard envelope.success, let payload = envelope.data else {
            let message = envelope.error?.message ?? envelope.detail ?? "AIOStreams search failed."
            if message.localizedCaseInsensitiveContains("credentials") { throw BackendError.unauthorized }
            throw BackendError.api(message: "AIOStreams: \(message)")
        }
        return Results(
            candidates: payload.results.enumerated().map { $1.candidate(id: "aiostreams#\($0)") },
            sourceErrors: payload.errors.map { "\($0.title): \($0.description)" }
        )
    }

    // MARK: - Wire types

    struct Envelope: Decodable {
        let success: Bool
        let detail: String?
        let error: APIError?
        let data: Payload?
    }

    struct APIError: Decodable {
        let code: String?
        let message: String?
    }

    struct Payload: Decodable {
        let results: [Result]
        let errors: [SourceError]
    }

    struct SourceError: Decodable {
        let title: String
        let description: String
    }

    struct Result: Decodable {
        let infoHash: String?
        let fileIdx: Int?
        let url: String?
        let nzbUrl: String?
        let filename: String?
        let folderName: String?
        let size: Int64?
        let folderSize: Int64?
        let type: String
        let service: String?
        let cached: Bool?
        let bingeGroup: String?
        let addon: String?
        let indexer: String?
        let message: String?
        let parsedFile: ParsedFile?

        struct ParsedFile: Decodable {
            let resolution: String?
            let quality: String?
            let encode: String?
            let releaseGroup: String?
            let visualTags: [String]?
            let audioTags: [String]?
            let languages: [String]?
            let seasons: [Int]?
            let episodes: [Int]?
            let seasonPack: Bool?
        }

        func candidate(id: String) -> StreamCandidate {
            let kind: StreamCandidate.Kind = switch type {
            case "debrid": .debrid
            case "usenet": .usenet
            case "http": .http
            case "p2p": .p2p
            default: .unknown
            }
            let label = [addon, service, indexer, message].compactMap { $0 }.joined(separator: " · ")
            return StreamCandidate(
                id: id,
                kind: kind,
                title: filename ?? folderName ?? "Stream",
                label: label,
                size: size,
                folderName: folderName,
                folderSize: folderSize,
                infoHash: infoHash,
                fileIndex: fileIdx.flatMap { $0 >= 0 ? $0 : nil },
                url: url.flatMap(URL.init(string:)),
                nzbURL: nzbUrl.flatMap(URL.init(string:)),
                service: service,
                cached: cached,
                bingeGroup: bingeGroup,
                traits: parsedFile.map {
                    StreamTraits(
                        resolution: $0.resolution,
                        quality: $0.quality,
                        encode: $0.encode,
                        releaseGroup: $0.releaseGroup,
                        visualTags: $0.visualTags ?? [],
                        audioTags: $0.audioTags ?? [],
                        languages: $0.languages ?? [],
                        seasons: $0.seasons ?? [],
                        episodes: $0.episodes ?? [],
                        seasonPack: $0.seasonPack ?? false
                    )
                }
            )
        }
    }
}
