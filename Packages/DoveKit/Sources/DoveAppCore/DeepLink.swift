import DoveKit
import Foundation

/// `dove://` links from widgets: `dove://watchlist`, `dove://library`, `dove://downloads`, `dove://settings`,
/// `dove://listening`, `dove://title/<id>`, `dove://search?q=<words>`.
public enum DeepLink {
    public static func url(_ host: String, _ path: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "dove"
        components.host = host
        if let path { components.path = "/" + path }
        return components.url!
    }

    public static func title(_ id: String) -> URL { url("title", id) }

    /// The screen a `dove://` link opens, for links that only navigate.
    public static func destination(for url: URL) -> AppModel.Destination? {
        guard url.scheme == "dove" else { return nil }
        switch url.host() {
        case "watchlist": return .watchlist
        case "library": return .library(nil)
        case "downloads": return .downloads
        case "settings": return .settings
        case "search":
            let words = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
            return .search(words?.isEmpty == false ? words : nil)
        case "title":
            let id = String(url.path().dropFirst()).removingPercentEncoding ?? ""
            return id.isEmpty ? nil : .title(id: id)
        default: return nil
        }
    }

    /// True when it was a `dove://` link (handled or not), so it is not taken for a magnet or a file.
    @MainActor
    static func open(_ url: URL, using app: AppModel) -> Bool {
        guard url.scheme == "dove" else { return false }
        if let destination = destination(for: url) {
            app.show(destination)
            return true
        }
        switch url.host() {
        case "listening":
            if app.audiobook.session != nil { app.audiobook.isPresented = true } else { Task { _ = await app.continueAudiobook() } }
        case "media":
            if let link = TitleLink(deepLink: url) { Task { await app.openTitle(link) } }
        case "plugin-link":
            // From the share extension: a file page an installed plugin knows.
            let address = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "url" }?.value
            app.show(.downloads)
            if let address, let page = URL(string: address), let link = app.plugins.link(for: page) {
                Task { app.incomingDownloadMessage = await app.getFile(from: link.call, id: link.id, kind: .books) }
            } else {
                app.incomingDownloadMessage = "No installed plugin knows this address."
            }
        default: break
        }
        return true
    }
}
