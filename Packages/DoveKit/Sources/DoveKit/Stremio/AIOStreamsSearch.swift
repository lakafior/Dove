import Foundation

/// AIOStreams Search API: the same results as its Stremio `/stream` route, but structured
/// (`infoHash`, `fileIdx`, `nzbUrl`, `service`, `cached`, `folderSize`, `parsedFile`…).
/// Docs: https://github.com/Viren070/AIOStreams/blob/main/packages/docs/content/docs/apis/search.mdx
///
/// `GET {origin}/api/v1/search?type=…&id=…` with `Authorization: Basic base64(uuid:password)`.
public struct AIOStreamsSearch: Sendable {
    public let origin: URL
    public let uuid: String
    /// Config variant (`&v=`): lets Dove ask for, say, an unfiltered list while Stremio keeps the filtered one.
    public let variant: String?
    private let password: String
    private let transport: any HTTPTransport

    public init(
        origin: URL,
        uuid: String,
        password: String,
        variant: String? = nil,
        transport: any HTTPTransport = URLSession.shared
    ) {
        self.origin = origin
        self.uuid = uuid
        self.password = password
        self.variant = variant.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        self.transport = transport
    }

    /// Recognises an AIOStreams manifest URL (`{origin}/stremio/{uuid}/{config}[/v/{variant}]/manifest.json[?v=…]`)
    /// and returns its parts.
    public static func instance(from manifestURL: URL) -> (origin: URL, uuid: String, variant: String?)? {
        let parts = manifestURL.pathComponents.filter { $0 != "/" }
        // `stremio`, uuid, config, …, `manifest.json`: the encrypted config segment is what tells AIOStreams apart
        // from AIOMetadata and other addons that also use `/stremio/{uuid}/manifest.json`.
        guard let index = parts.firstIndex(of: "stremio"),
              parts.count >= index + 4,
              parts.last == "manifest.json",
              UUID(uuidString: parts[index + 1]) != nil,
              var components = URLComponents(url: manifestURL, resolvingAgainstBaseURL: false)
        else { return nil }
        let queryVariant = components.queryItems?.first { $0.name == "v" }?.value
        let pathVariant = parts.firstIndex(of: "v").flatMap { $0 > index + 2 && $0 + 1 < parts.count - 1 ? parts[$0 + 1] : nil }
        components.path = ""
        components.query = nil
        guard let origin = components.url else { return nil }
        return (origin, parts[index + 1], pathVariant ?? queryVariant)
    }

    public struct Results: Sendable {
        public let candidates: [StreamCandidate]
        /// Per-source failures reported by AIOStreams (e.g. an expired key in one of its services).
        public let sourceErrors: [String]
    }

    /// Checks the password with `GET /api/v1/user`.
    public func validate() async throws {
        _ = try await variants()
    }

    public struct Variant: Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String?
        public let enabled: Bool
        public var displayName: String { name.map { "\($0) (\(id))" } ?? id }
    }

    /// The config variants defined in this configuration, from `GET /api/v1/user`.
    /// That route answers with the whole configuration, API keys included: only `success` and each
    /// variant's id, name and enabled flag are decoded (not its script, which may hold keys); the rest is dropped.
    public func variants() async throws -> [Variant] {
        var request = URLRequest(url: origin.appending(path: "api/v1/user"))
        request.timeoutInterval = 20
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        let status = try? JSONDecoder().decode(Status.self, from: data)
        if status?.success == true {
            return (status?.data?.userData?.variants ?? []).map {
                Variant(id: $0.id, name: $0.name, enabled: $0.enabled ?? true)
            }
        }
        if response.statusCode == 401 || response.statusCode == 403
            || status?.error?.message?.localizedCaseInsensitiveContains("password") == true
            || status?.error?.message?.localizedCaseInsensitiveContains("credentials") == true {
            throw BackendError.unauthorized
        }
        throw BackendError.api(message: "AIOStreams: \(status?.error?.message ?? "could not check the password")")
    }

    private var authorization: String {
        "Basic " + Data("\(uuid):\(password)".utf8).base64EncodedString()
    }

    /// `success`, `error` and variant labels only; the rest of the user's config is never decoded.
    struct Status: Decodable {
        let success: Bool
        let error: APIError?
        let data: UserPayload?

        struct UserPayload: Decodable {
            let userData: UserData?
        }

        struct UserData: Decodable {
            let variants: [VariantLabel]?
        }

        struct VariantLabel: Decodable {
            let id: String
            let name: String?
            let enabled: Bool?
        }
    }

    /// A variant that lifts every filter and limit, so Dove gets the full list and filters on the phone.
    /// Only fields AIOStreams lets variants write are touched (its `FIELD_META`); sorting and preferences stay.
    /// Instructions that match nothing in a given configuration are skipped by AIOStreams.
    public static let unfilteredVariantID = "dove"
    public static let unfilteredVariantScript = """
        # Added by Dove: torrents and debrid, unfiltered. Dove filters on the phone and searches Usenet with its
        # own indexers; Stremio keeps the base config.
        unset resultLimits
        unset size
        unset excludeSeederRange
        unset requiredSeederRange
        unset excludeAgeRange
        unset requiredAgeRange
        set excludeUncached = false
        set excludeCached = false
        set excludeSeasonPacks = false
        clear excludedResolutions
        clear excludedQualities
        clear excludedEncodes
        clear excludedVisualTags
        clear excludedAudioTags
        clear excludedAudioChannels
        clear excludedLanguages
        clear excludedSubtitles
        set excludedStreamTypes = ["usenet", "stremio-usenet", "http", "live", "youtube", "external"]
        clear excludedReleaseGroups
        clear excludedKeywords
        clear excludedRegexPatterns
        clear excludedStreamExpressions
        clear syncedExcludedRegexUrls
        clear syncedExcludedStreamExpressionUrls
        clear requiredResolutions
        clear requiredQualities
        clear requiredEncodes
        clear requiredVisualTags
        clear requiredAudioTags
        clear requiredAudioChannels
        clear requiredLanguages
        clear requiredSubtitles
        clear requiredStreamTypes
        clear requiredReleaseGroups
        clear requiredKeywords
        clear requiredRegexPatterns
        clear requiredStreamExpressions
        clear syncedRequiredRegexUrls
        clear syncedRequiredStreamExpressionUrls
        """

    /// Addon types that give only Usenet, plain HTTP or live streams (AIOStreams presets' `METADATA.ID` and
    /// `SUPPORTED_STREAM_TYPES`; `hdhub` is mostly HTTP). Disabled by type, so addons added later are covered too.
    static let nonTorrentPresetTypes = [
        "usenet-streamer", "newznab", "nzbhydra", "streamnzb", "davex",
        "easynews", "easynewsPlus", "easynewsPlusPlus", "easynews-search",
        "astream", "webstreamr", "nuvio-streams", "stremio-gdrive", "yastream", "penguplay", "flix-streams", "hdhub",
        "argentina-tv", "usa-tv", "usa-tv-next",
    ]

    /// Usenet services (and AIOStreams-as-a-service); with them off, no addon can turn a result into Usenet.
    static let usenetServices = ["nzbdav", "altmount", "easynews", "stremio_nntp", "stremthru_newz", "aiostreams"]

    /// Dove's variant: the unfiltered base, Usenet services and Usenet/HTTP addons off. Disabling (not just
    /// excluding the results) keeps AIOStreams from querying them, so Dove's searches cost the user's indexers
    /// nothing; Dove searches Usenet with its own indexers. Custom addons are matched by name or manifest.
    /// P2P stays: a bare info hash is still a torrent Dove can send to a debrid.
    public static func doveVariantScript(presets: [[String: Any]]) -> String {
        var lines = [unfilteredVariantScript, "# Torrents and debrid only: Usenet services and Usenet/HTTP addons are off for Dove."]
        lines += usenetServices.map { "disable services[id=\($0)]" }
        // Addons limited to a service turned off above would be left with none: let them use the rest.
        lines.append("remove presets[*].options.services")
        lines.append("remove presets[*].options.httpProviders")
        lines += nonTorrentPresetTypes.map { "disable presets[type=\($0)]" }
        let customUsenet = presets.filter { preset in
            guard preset["type"] as? String == "custom", let options = preset["options"] as? [String: Any] else { return false }
            let text = [options["name"], options["manifestUrl"]].compactMap { $0 as? String }.joined(separator: " ").lowercased()
            return ["usenet", "nzb", "newznab", "easynews"].contains { text.contains($0) }
        }
        let ids = customUsenet.compactMap { $0["instanceId"] as? String }.filter { !$0.contains("\"") }
        if !ids.isEmpty {
            lines.append("# Custom addons that look like Usenet.")
            lines += ids.map { "disable presets[instanceId=\"\($0)\"]" }
        }
        return lines.joined(separator: "\n")
    }

    /// Creates Dove's variant, or rewrites its script (addons may have changed since). Saves the way AIOStreams'
    /// own config page does: `GET /api/v1/user?raw=true`, edit `variants`, `PUT /api/v1/user` with `{"config": …}`.
    /// The configuration is handled as untyped JSON so every field the server sent goes back unchanged.
    /// AIOStreams validates the whole config (variant scripts included) and rejects the save if anything is off.
    public func saveDoveVariant(name: String = "Dove") async throws {
        try await editConfig { config in
            let script = Self.doveVariantScript(presets: config["presets"] as? [[String: Any]] ?? [])
            var variants = config["variants"] as? [[String: Any]] ?? []
            if let index = variants.firstIndex(where: { ($0["id"] as? String)?.lowercased() == Self.unfilteredVariantID }) {
                variants[index]["script"] = script
                variants[index]["enabled"] = true
            } else {
                variants.append(["id": Self.unfilteredVariantID, "name": name, "enabled": true, "script": script])
            }
            config["variants"] = variants
        }
    }

    private func editConfig(_ change: (inout [String: Any]) -> Void) async throws {
        var get = URLRequest(url: origin.appending(path: "api/v1/user").appending(queryItems: [URLQueryItem(name: "raw", value: "true")]))
        get.timeoutInterval = 20
        get.setValue(authorization, forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(get)
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["success"] as? Bool == true,
              let payload = envelope["data"] as? [String: Any],
              var config = payload["userData"] as? [String: Any]
        else {
            if response.statusCode == 401 || response.statusCode == 403 { throw BackendError.unauthorized }
            throw BackendError.api(message: "AIOStreams did not return your configuration.")
        }
        change(&config)

        var put = URLRequest(url: origin.appending(path: "api/v1/user"))
        put.httpMethod = "PUT"
        put.timeoutInterval = 30
        put.setValue(authorization, forHTTPHeaderField: "Authorization")
        put.setValue("application/json", forHTTPHeaderField: "Content-Type")
        put.httpBody = try JSONSerialization.data(withJSONObject: ["config": config])
        let (saved, savedResponse) = try await transport.send(put)
        let status = try? JSONDecoder().decode(Status.self, from: saved)
        guard status?.success == true else {
            if savedResponse.statusCode == 401 || savedResponse.statusCode == 403 { throw BackendError.unauthorized }
            throw BackendError.api(message: "AIOStreams refused the change: \(status?.error?.message ?? "HTTP \(savedResponse.statusCode)")")
        }
    }

    public func search(type: MediaType, id: String) async throws -> Results {
        var components = URLComponents(url: origin.appending(path: "api/v1/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "type", value: type.rawValue), URLQueryItem(name: "id", value: id)]
            + (variant.map { [URLQueryItem(name: "v", value: $0)] } ?? [])
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 60
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        let (data, response) = try await transport.send(request)
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        guard let envelope else { throw response.backendError ?? BackendError.invalidResponse }
        guard envelope.success, let payload = envelope.data else {
            let message = envelope.error?.message ?? envelope.detail ?? "AIOStreams search failed."
            if message.localizedCaseInsensitiveContains("credentials") { throw BackendError.unauthorized }
            if let variant, message.localizedCaseInsensitiveContains("variant") {
                throw BackendError.api(
                    message: "Your AIOStreams configuration has no enabled variant \"\(variant)\". Create it in AIOStreams (Miscellaneous → Variants) and save, or pick another one in Dove's Settings."
                )
            }
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

    struct LossyDouble: Decodable {
        let value: Double?

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            value = (try? container.decode(Double.self)) ?? (try? container.decode(String.self)).flatMap(Double.init)
        }
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
        let seeders: Int?
        /// Hours since upload. A number in the schema; tolerated as text, and ignored when neither.
        let age: LossyDouble?
        let `private`: Bool?
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
            let folderSeasons: [Int]?
        }

        func candidate(id: String, now: Date = .now) -> StreamCandidate {
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
                traits: traits,
                seeders: seeders,
                provider: "AIOStreams",
                addon: addon,
                tracker: indexer,
                isPrivate: `private`,
                published: age?.value.map { now.addingTimeInterval(-$0 * 3600) }
            )
        }

        private var traits: StreamTraits? {
            parsedFile.map {
                StreamTraits(
                    resolution: $0.resolution,
                    quality: $0.quality,
                    encode: $0.encode,
                    releaseGroup: $0.releaseGroup,
                    visualTags: $0.visualTags ?? [],
                    audioTags: $0.audioTags ?? [],
                    languages: ($0.languages ?? []).map(LanguageName.code),
                    seasons: $0.seasons ?? [],
                    episodes: $0.episodes ?? [],
                    seasonPack: $0.seasonPack ?? false,
                    folderSeasons: $0.folderSeasons ?? []
                )
            }
        }
    }
}
