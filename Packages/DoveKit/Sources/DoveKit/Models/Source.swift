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
    /// An NZB link, with the release name to give the job (indexers often serve NZBs under random names).
    case nzbURL(URL, name: String? = nil)
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
        case .torrentURL(let url), .hosterURL(let url, _), .nzbURL(let url, _): url.absoluteString
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
        case .nzbURL(_, let name?) where !name.isEmpty:
            return name
        case .torrentURL(let url), .hosterURL(let url, _), .nzbURL(let url, _):
            return (url.host() ?? "") + url.path()
        }
    }
}

extension Source {
    /// A magnet for an info hash, named `dn` when the release name is known: services show it until the torrent's
    /// metadata arrives (and some keep it), instead of the bare hash.
    public static func magnet(infoHash: String, name: String?) -> Source {
        var magnet = "magnet:?xt=urn:btih:\(infoHash.lowercased())"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
           let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) {
            magnet += "&dn=\(encoded)"
        }
        return .magnet(magnet)
    }
}
