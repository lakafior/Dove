import Foundation

/// The broad family a source belongs to. Backends declare which kinds they accept,
/// and the router uses this to pick a backend automatically.
public enum SourceKind: String, Sendable, Codable, CaseIterable {
    case torrent
    case hoster
    case nzb
}

/// Something the user wants added to a library backend.
public enum Source: Sendable, Equatable {
    case magnet(String)
    case torrentURL(URL)
    case torrentFile(data: Data, filename: String)
    /// A file hoster's link, with the password some hosters put on a file.
    case hosterURL(URL, password: String? = nil)
    case nzbURL(URL)
    case nzbFile(data: Data, filename: String)

    public var kind: SourceKind {
        switch self {
        case .magnet, .torrentURL, .torrentFile: .torrent
        case .hosterURL: .hoster
        case .nzbURL, .nzbFile: .nzb
        }
    }
}

extension Source: Identifiable {
    public var id: String {
        switch self {
        case .magnet(let magnet): magnet
        case .torrentURL(let url), .hosterURL(let url, _), .nzbURL(let url): url.absoluteString
        case .torrentFile(_, let name), .nzbFile(_, let name): name
        }
    }
}

extension Source {
    /// Something readable for a confirmation screen: the magnet's name, a file name, or the link's host and path.
    public var displayName: String {
        switch self {
        case .magnet(let magnet):
            let items = URLComponents(string: magnet)?.queryItems ?? []
            if let name = items.first(where: { $0.name.lowercased() == "dn" })?.value?.replacingOccurrences(of: "+", with: " "), !name.isEmpty {
                return name
            }
            let topic = items.first { $0.name.lowercased() == "xt" }?.value ?? magnet
            return topic.replacingOccurrences(of: "urn:btih:", with: "", options: .caseInsensitive)
        case .torrentFile(_, let name), .nzbFile(_, let name):
            return name
        case .torrentURL(let url), .hosterURL(let url, _), .nzbURL(let url):
            return (url.host() ?? "") + url.path()
        }
    }
}
