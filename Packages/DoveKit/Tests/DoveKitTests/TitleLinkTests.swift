import Foundation
import Testing
@testable import DoveKit

struct TitleLinkTests {
    private func link(_ text: String) -> TitleLink? { URL(string: text).flatMap(TitleLink.init(url:)) }

    @Test func readsTheSitesPeopleShareFrom() {
        #expect(link("https://www.imdb.com/title/tt1856101/?ref_=nv_sr_srsg_0") == .imdb("tt1856101"))
        #expect(link("https://m.imdb.com/title/tt11280740/episodes") == .imdb("tt11280740"))
        #expect(link("https://www.themoviedb.org/movie/335984-blade-runner-2049") == .tmdb(id: 335984, type: .movie))
        #expect(link("https://www.themoviedb.org/tv/95396-severance?language=pl") == .tmdb(id: 95396, type: .series))
        #expect(link("https://tv.apple.com/pl/movie/titanic/umc.cmc.4pk3ycbkkgplxmkunz6qbhe5x") == .named(title: "titanic", year: nil, type: .movie))
        #expect(link("https://tv.apple.com/us/show/severance/umc.cmc.1srk2goyh2q2zdxcx605w8vtx") == .named(title: "severance", year: nil, type: .series))
        #expect(link("https://letterboxd.com/film/dune-part-two/") == .named(title: "dune part two", year: nil, type: .movie))
        #expect(link("https://letterboxd.com/film/dune-2021/") == .named(title: "dune", year: 2021, type: .movie))
        #expect(link("https://trakt.tv/movies/blade-runner-2049-2017") == .named(title: "blade runner 2049", year: 2017, type: .movie))
        #expect(link("https://trakt.tv/shows/severance") == .named(title: "severance", year: nil, type: .series))
        #expect(link("https://www.rottentomatoes.com/m/titanic") == .named(title: "titanic", year: nil, type: .movie))
        #expect(link("https://www.justwatch.com/pl/serial/rozdzielenie") == .named(title: "rozdzielenie", year: nil, type: .series))
        #expect(link("https://www.imdb.com/name/nm0000138/") == nil, "a person, not a title")
        #expect(link("https://rapidgator.net/file/abc/movie.mkv") == nil)
    }

    @Test func titlePagesAreNotHosterLinks() {
        #expect(SourceDetector.detect("https://www.imdb.com/title/tt1856101/") == nil)
        #expect(SourceDetector.detect("https://rapidgator.net/file/abc") == .hosterURL(URL(string: "https://rapidgator.net/file/abc")!))
        #expect(TitleLink.first(in: "Check this out: https://tv.apple.com/pl/movie/titanic/umc.cmc.4pk") == .named(title: "titanic", year: nil, type: .movie))
    }

    @Test func deepLinksRoundTrip() {
        for link in [TitleLink.imdb("tt1"), .tmdb(id: 5, type: .series), .named(title: "blade runner", year: 2017, type: .movie), .named(title: "x", year: nil, type: nil)] {
            #expect(TitleLink(deepLink: link.deepLink) == link)
        }
    }

    @Test func imdbLinksResolveThroughTMDBFind() async throws {
        let transport = MockTransport()
        await transport.stub("3/find/tt1856101", json: #"{"movie_results":[{"id":335984,"title":"Blade Runner 2049","release_date":"2017-10-04"}],"tv_results":[]}"#)
        let addons = AddonSet(addons: [], tmdb: TMDBMetadata(key: "0123456789abcdef0123456789abcdef", transport: transport))
        let media = await addons.resolve(.imdb("tt1856101"))
        #expect(media?.name == "Blade Runner 2049" && media?.type == .movie && media?.id == "tmdb:335984")
    }
}
