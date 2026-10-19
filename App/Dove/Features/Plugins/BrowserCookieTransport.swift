import DoveKit
import Foundation
import WebKit

/// The built-in browser's cookies on a plugin's requests: `resolve` then speaks as the session the user has
/// on the site (the browser keeps its cookies in the default web data store), so a login, or a captcha
/// solved there, carries to the plugin's fetches. The hosts are the plugin's own either way (`PluginHostPolicy`
/// still decides what may be reached), and nothing the plugin's fetches set is written back.
struct BrowserCookieTransport: HTTPTransport {
    let wrapped: any HTTPTransport

    init(wrapping wrapped: any HTTPTransport = URLSession.shared) {
        self.wrapped = wrapped
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        if let url = request.url, let cookies = await Self.cookies(for: url) {
            let given = request.value(forHTTPHeaderField: "Cookie")
            request.setValue([given, cookies].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        return try await wrapped.send(request)
    }

    /// The browser's `Cookie` header for a URL, the way `HTTPCookieStorage` would send it: cookies the
    /// default web data store holds for the host, the path and the scheme.
    private static func cookies(for url: URL) async -> String? {
        let cookies = await browserCookies()
        let host = url.host() ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        let header = cookies
            .filter { cookie in
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                guard host == domain || host.hasSuffix("." + domain) else { return false }
                guard !cookie.isSecure || url.scheme?.lowercased() == "https" else { return false }
                return path.hasPrefix(cookie.path.isEmpty ? "/" : cookie.path)
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        return header.isEmpty ? nil : header
    }

    /// What a cookie needs to be matched, copied out of WebKit's store.
    private struct Cookie: Sendable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let isSecure: Bool
    }

    /// WebKit's cookie store belongs to the main actor: it is read there, and only plain values leave it.
    @MainActor
    private static func browserCookies() async -> [Cookie] {
        await WKWebsiteDataStore.default().httpCookieStore.allCookies().map {
            Cookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, isSecure: $0.isSecure)
        }
    }
}
