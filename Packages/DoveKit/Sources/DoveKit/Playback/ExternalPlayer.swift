import Foundation

/// One file handed to a player: the link, and a name to read the show and episode from when the link's path
/// does not carry one (TorBox's `/dld/<uuid>`).
public struct PlayEntry: Sendable, Equatable {
    public var url: URL
    public var filename: String?

    public init(url: URL, filename: String? = nil) {
        self.url = url
        self.filename = filename
    }
}

/// The apps Dove hands links to. All but Kodi are opened by URL scheme; Kodi is driven over JSON-RPC
/// (`KodiClient`). Schemes come from the players' own docs where they exist, otherwise from other apps that
/// call them (Stremio, AIOStreams); "Custom" covers a player whose scheme changes.
public enum ExternalPlayer: String, Sendable, CaseIterable, Codable, Identifiable {
    case infuse
    case vlc
    case outplayer
    case senPlayer
    case nPlayer
    case vidHub
    case kodi
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .infuse: "Infuse"
        case .vlc: "VLC"
        case .outplayer: "Outplayer"
        case .senPlayer: "SenPlayer"
        case .nPlayer: "nPlayer"
        case .vidHub: "VidHub"
        case .kodi: "Kodi"
        case .custom: "Custom"
        }
    }

    /// Only Infuse (8.4.7+, repeated `url`s) and Kodi (its video playlist) take several files at once;
    /// the others get the first one.
    public var takesPlaylist: Bool {
        self == .infuse || self == .kodi
    }

    /// The scheme `canOpenURL` checks to tell whether the app is installed (listed in the app's
    /// `LSApplicationQueriesSchemes`). Nil for Kodi (another device) and Custom.
    public var scheme: String? {
        switch self {
        case .infuse: "infuse"
        case .vlc: "vlc-x-callback"
        case .outplayer: "outplayer"
        case .senPlayer: "senplayer"
        case .nPlayer: "nplayer-https"
        case .vidHub: "open-vidhub"
        case .kodi, .custom: nil
        }
    }

    /// The URL that opens `entries` in this player, or nil for Kodi, for no entries, or for a custom template
    /// without `{url}`/`{encodedUrl}`. Players without playlists get the first entry.
    public func link(for entries: [PlayEntry], customTemplate: String = "") -> URL? {
        guard let first = entries.first else { return nil }
        let url = first.url.absoluteString
        switch self {
        case .infuse:
            return Self.infuseLink(for: entries)
        case .vlc:
            // `stream` plays at once; plain `vlc://` asks whether to download or stream first.
            return PlayerLink.fill("vlc-x-callback://x-callback-url/stream?url={encodedUrl}", with: first)
        case .outplayer:
            return PlayerLink.fill("outplayer://x-callback-url/play?url={encodedUrl}", with: first)
        case .senPlayer:
            return PlayerLink.fill("senplayer://x-callback-url/play?url={encodedUrl}", with: first)
        case .nPlayer:
            // nPlayer takes the link itself with its scheme prefixed: `nplayer-https://host/path`.
            return URL(string: "nplayer-" + url)
        case .vidHub:
            return PlayerLink.fill("open-vidhub://x-callback-url/open?url={encodedUrl}", with: first)
        case .kodi:
            return nil
        case .custom:
            return PlayerLink.fill(customTemplate, with: first)
        }
    }

    /// Several `url`s play in order as a temporary playlist (Infuse 8.4.7+), each followed by its `filename`.
    private static func infuseLink(for entries: [PlayEntry]) -> URL? {
        var parameters: [String] = []
        for entry in entries {
            guard let url = PlayerLink.encode(entry.url.absoluteString) else { return nil }
            parameters.append("url=\(url)")
            if let filename = entry.filename, let name = PlayerLink.encode(filename) { parameters.append("filename=\(name)") }
        }
        return URL(string: "infuse://x-callback-url/play?" + parameters.joined(separator: "&"))
    }
}

/// Fills player URL templates.
public enum PlayerLink {
    /// Placeholders a custom template may use.
    public static let placeholders = ["{url}", "{encodedUrl}", "{filename}"]

    /// Only RFC 3986 unreserved characters stay literal. `URLQueryItem` leaves `+`, `/`, `?` and `:` as they are,
    /// and Infuse decodes `+` as a space, which breaks links whose file name has a `+` (the server answers 400).
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func encode(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: unreserved)
    }

    /// `{url}` is the link as it is (for schemes that take it after `scheme://`), `{encodedUrl}` the link
    /// percent-encoded for a query, `{filename}` the encoded file name (empty without one). Nil when the template
    /// names no link or the result is not a URL.
    public static func fill(_ template: String, with entry: PlayEntry) -> URL? {
        let template = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard template.contains("{url}") || template.contains("{encodedUrl}"),
              let encoded = encode(entry.url.absoluteString) else { return nil }
        let filename = entry.filename.flatMap(encode) ?? ""
        let filled = template
            .replacingOccurrences(of: "{encodedUrl}", with: encoded)
            .replacingOccurrences(of: "{filename}", with: filename)
            .replacingOccurrences(of: "{url}", with: entry.url.absoluteString)
        return URL(string: filled)
    }
}
