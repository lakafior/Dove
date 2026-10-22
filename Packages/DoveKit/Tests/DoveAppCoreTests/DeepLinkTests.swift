import DoveAppCore
import Foundation
import Testing

struct DeepLinkTests {
    @Test func buildsWidgetLinks() {
        #expect(DeepLink.url("watchlist").absoluteString == "dove://watchlist")
        #expect(DeepLink.title("tt0120338").absoluteString == "dove://title/tt0120338")
    }

    @Test func navigationLinksNameTheirScreen() throws {
        let cases: [(String, String)] = [
            ("dove://watchlist", "watchlist"),
            ("dove://library", "library"),
            ("dove://downloads", "downloads"),
            ("dove://settings", "settings"),
        ]
        for (link, expected) in cases {
            let destination = try #require(DeepLink.destination(for: URL(string: link)!))
            #expect(Self.name(destination) == expected)
        }
    }

    @Test func titleLinkCarriesTheID() throws {
        let destination = try #require(DeepLink.destination(for: DeepLink.title("book:Lem Solaris")))
        guard case .title(let id) = destination else {
            Issue.record("expected a title, got \(destination)")
            return
        }
        #expect(id == "book:Lem Solaris")
    }

    @Test func linksThatDoMoreThanNavigateHaveNoDestination() {
        #expect(DeepLink.destination(for: URL(string: "dove://listening")!) == nil)
        #expect(DeepLink.destination(for: URL(string: "dove://media?imdb=tt0120338&type=movie")!) == nil)
        #expect(DeepLink.destination(for: URL(string: "dove://title/")!) == nil)
        #expect(DeepLink.destination(for: URL(string: "magnet:?xt=urn:btih:abc")!) == nil)
    }

    private static func name(_ destination: AppModel.Destination) -> String {
        switch destination {
        case .watchlist: "watchlist"
        case .library: "library"
        case .downloads: "downloads"
        case .settings: "settings"
        default: "other"
        }
    }
}
