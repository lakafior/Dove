import Foundation

/// Torrent links from Dove's own Torznab indexers (Jackett, Prowlarr) carry the indexer's API key and often
/// point to a host only the phone reaches, so they never go to a service as a URL (Offcloud would fetch it
/// itself). The phone fetches the `.torrent`, or follows the indexer's redirect to a magnet, and the service
/// gets the file or the magnet.
public enum IndexerTorrent {
    /// `.torrentURL` sources are resolved; everything else passes through.
    public static func prepare(_ source: Source, transport: any HTTPTransport = RedirectlessTransport()) async throws -> Source {
        guard case .torrentURL(let url) = source else { return source }
        return try await resolve(url, transport: transport)
    }

    static func resolve(_ url: URL, transport: any HTTPTransport, redirects: Int = 0) async throws -> Source {
        let (data, response) = try await transport.send(URLRequest(url: url))
        if (300..<400).contains(response.statusCode),
           let location = response.value(forHTTPHeaderField: "Location"),
           let target = URL(string: location, relativeTo: url)?.absoluteURL {
            if target.scheme?.lowercased() == "magnet" { return .magnet(target.absoluteString) }
            guard redirects < 5, target.scheme == "http" || target.scheme == "https" else {
                throw BackendError.api(message: "The indexer's link went nowhere usable.")
            }
            return try await resolve(target, transport: transport, redirects: redirects + 1)
        }
        if let error = response.backendError { throw error }
        // Some indexers answer with the magnet as text.
        if let text = String(data: data.prefix(2048), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           text.hasPrefix("magnet:") {
            return .magnet(text)
        }
        // A torrent is a bencoded dictionary; anything else is an error page.
        guard data.first == UInt8(ascii: "d") else {
            throw BackendError.api(message: "The indexer did not return a torrent file.")
        }
        return .torrentFile(data: data, filename: filename(from: response, url: url))
    }

    static func filename(from response: HTTPURLResponse, url: URL) -> String {
        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           let range = disposition.range(of: "filename=") {
            let name = disposition[range.upperBound...]
                .split(separator: ";").first.map(String.init)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if let name, !name.isEmpty { return name.hasSuffix(".torrent") ? name : name + ".torrent" }
        }
        // Jackett's links end in `/dl/<tracker>/`; the path says nothing useful then.
        let last = url.lastPathComponent
        return last.lowercased().hasSuffix(".torrent") ? last : "download.torrent"
    }
}

/// `URLSession` without following redirects, so a redirect to `magnet:` is seen rather than failing.
/// Logs like the shared transport: host only, path private, never the query (it carries API keys).
public struct RedirectlessTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let host = request.url?.host() ?? ""
        let path = request.url?.path() ?? ""
        do {
            let (data, response) = try await URLSession.shared.data(for: request, delegate: NoRedirects())
            guard let http = response as? HTTPURLResponse else { throw BackendError.invalidResponse }
            HTTPLog.logger.debug("GET \(host, privacy: .public)\(path, privacy: .private) → \(http.statusCode)")
            return (data, http)
        } catch {
            HTTPLog.logger.error("GET \(host, privacy: .public)\(path, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
