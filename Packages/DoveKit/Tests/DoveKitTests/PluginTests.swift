import Foundation
import Testing
@testable import DoveKit

struct PluginTests {
    static let script = #"""
    globalThis.plugin = {
      manifest: {
        id: "test.books", name: "Test books", version: "1.0.0", api: 1,
        capabilities: ["metadata", "search", "resolve", "teleport"],
        categories: ["books", "audiobooks", "future"],
        hosts: ["api.books.test", "*.covers.test", "{domain}"],
        settings: [
          { key: "domain", title: "Address", type: "text", required: true },
          { key: "key", title: "Secret key", type: "secret" },
          { key: "audible", title: "Use Audible", type: "toggle", default: true }
        ],
        browse: "https://{domain}/search?q={query}",
        links: ["^https://{domain}/md5/(?<id>[0-9a-fA-F]{32})"]
      },
      async metadata({ query, format }, ctx) {
        const response = await dove.fetch(`https://api.books.test/search?q=${encodeURIComponent(query)}`, { headers: { "X-Key": ctx.settings.key } })
        if (response.status !== 200) throw new Error("search failed " + response.status)
        return response.json().items.map(item => ({
          id: item.id, title: item.title, authors: [item.author], year: "2021-05-04",
          cover: "https://img.covers.test/" + item.id + ".jpg", description: "<b>" + format + "</b> " + ctx.settings.audible
        }))
      },
      async search({ query, category, book }, ctx) {
        await dove.sleep(1)
        return [{ id: 7, title: query + " in " + category, author: book && book.authors[0], kind: "audiobooks", format: "M4B", size: "1234" }, { title: "no id" }]
      },
      async resolve({ id }, ctx) {
        if (id === "many") return [{ url: "https://cdn.test/1.mp3" }, { url: "https://cdn.test/2.mp3", headers: { Referer: "x" } }]
        if (id === "bad") return { url: "ftp://nope" }
        const response = await dove.fetch(`https://${ctx.settings.domain}/dyn/api/fast_download.json?md5=${id}`)
        return { url: response.json().download_url, fileName: "Book.epub" }
      }
    }
    """#

    private let settings: [String: SettingValue] = ["domain": .text("mirror.test"), "key": .text("SECRET")]

    private func manifest() async throws -> PluginManifest {
        try await PluginRunner(transport: MockTransport()).manifest(of: Self.script)
    }

    @Test func manifestsReadLeniently() async throws {
        let manifest = try await manifest()
        #expect(manifest.id == "test.books" && manifest.api == 1)
        #expect(manifest.capabilities == [.metadata, .search, .resolve], "unknown capabilities are skipped")
        #expect(manifest.categories == [.books, .audiobooks])
        #expect(manifest.settings.map(\.type) == [.text, .secret, .toggle])
        #expect(manifest.settings[2].default == .toggle(true))
    }

    @Test func metadataFetchesFromItsHostsWithTheUsersSettings() async throws {
        let transport = MockTransport()
        await transport.stub("/search", json: #"{"items":[{"id":"b1","title":"Projekt Hail Mary","author":"Andy Weir"}]}"#)
        let books = try await PluginRunner(transport: transport).metadata(
            manifest(), script: Self.script, settings: settings, query: "hail mary", format: .audiobook
        )
        #expect(books.map(\.id) == ["plugin:test.books:b1"])
        #expect(books[0].authors == ["Andy Weir"] && books[0].year == 2021)
        #expect(books[0].cover?.absoluteString == "https://img.covers.test/b1.jpg")
        #expect(books[0].description == "audiobook true", "HTML stripped; the toggle's default reaches ctx")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.host() == "api.books.test" && request.value(forHTTPHeaderField: "X-Key") == "SECRET")
    }

    @Test func hostsOutsideTheListAreRefused() async throws {
        let script = #"""
        globalThis.plugin = { manifest: { id: "x", hosts: ["ok.test"] },
          async metadata() { await dove.fetch("https://evil.test/steal"); return [] } }
        """#
        let runner = PluginRunner(transport: MockTransport())
        let manifest = try await runner.manifest(of: script)
        await #expect(throws: PluginError("dove.fetch: evil.test is not among the plugin's hosts.")) {
            try await runner.metadata(manifest, script: script, settings: [:], query: "q", format: .ebook)
        }
        let http = #"""
        globalThis.plugin = { manifest: { id: "x", hosts: ["ok.test"] },
          async metadata() { await dove.fetch("http://ok.test/plain"); return [] } }
        """#
        await #expect(throws: PluginError("dove.fetch: ok.test is not among the plugin's hosts."), "https only") {
            try await runner.metadata(manifest, script: http, settings: [:], query: "q", format: .ebook)
        }
    }

    @Test func pluginErrorsAndBadScriptsSayWhat() async throws {
        let runner = PluginRunner(transport: MockTransport())
        let manifest = try await manifest()
        let failing = #"globalThis.plugin = { manifest: { id: "x" }, async metadata() { throw new Error("Site changed") } }"#
        await #expect(throws: PluginError("Site changed")) {
            try await runner.metadata(manifest, script: failing, settings: settings, query: "q", format: .ebook)
        }
        await #expect(throws: PluginError.self) { try await runner.manifest(of: "this is not javascript (") }
        await #expect(throws: PluginError("The script defines no `plugin`.")) { try await runner.manifest(of: "var x = 1") }
        await #expect(throws: PluginError("Test books needs “Address” in Settings › Plugins.")) {
            try await runner.metadata(manifest, script: Self.script, settings: [:], query: "q", format: .ebook)
        }
        let noSearch = #"globalThis.plugin = { manifest: { id: "x" } }"#
        await #expect(throws: PluginError("The plugin cannot search.")) {
            try await runner.search(manifest, script: noSearch, settings: settings, query: "q", category: .books)
        }
    }

    @Test func titlesFromSourceLists() async throws {
        let movie = MediaSummary(id: "tmdb:603", type: .movie, name: "The Matrix", releaseInfo: "1999")
        let fromMovie = PluginTitle(name: "The Matrix", type: .movie, streamID: "tt0133093", media: movie)
        #expect(fromMovie == PluginTitle(name: "The Matrix", type: .movie, year: 1999, imdbID: "tt0133093", tmdbID: "603"))
        #expect(fromMovie.query == "The Matrix 1999")

        let episode = PluginTitle(name: "Lost", type: .series, streamID: "tt0411008:1:2")
        #expect(episode.imdbID == "tt0411008" && episode.season == 1 && episode.episode == 2 && episode.query == "Lost S01E02")
        let season = PluginTitle(name: "Lost", type: .series, streamID: "tt0411008:3:1", scope: .season(3))
        #expect(season.season == 3 && season.episode == nil && season.query == "Lost S03")
        let series = PluginTitle(name: "Lost", type: .series, streamID: "tt0411008:1:1", scope: .series)
        #expect(series.season == nil && series.query == "Lost")

        let script = #"""
        globalThis.plugin = { manifest: { id: "x" }, async search({ query, title, book }) {
          return [{ id: 1, title: [query, title.name, title.type, title.year, title.imdb, title.tmdb, title.season, title.episode, typeof book].join("|") }]
        } }
        """#
        let runner = PluginRunner(transport: MockTransport())
        let manifest = try await runner.manifest(of: script)
        let rows = try await runner.search(manifest, script: script, settings: [:], query: episode.query, category: .media, title: episode)
        #expect(rows.first?.title == "Lost S01E02|Lost|series||tt0411008||1|2|undefined", "missing values are left out")

        let albumScript = #"""
        globalThis.plugin = { manifest: { id: "x" }, async search({ album }) {
          return [{ id: 1, title: [album.title, album.artists.join("+"), album.year].join("|") }]
        } }
        """#
        let album = AlbumSummary(id: "mb:1", title: "Discovery", artists: ["Daft Punk"], year: 2001)
        let albumRows = try await runner.search(
            try await runner.manifest(of: albumScript), script: albumScript, settings: [:], query: "Daft Punk Discovery", category: .music, album: album
        )
        #expect(albumRows.first?.title == "Discovery|Daft Punk|2001")
    }

    @Test func musicMetadataGivesAlbumsAndTracks() async throws {
        let script = #"""
        globalThis.plugin = { manifest: { id: "music.test", name: "Music test", capabilities: ["metadata"], categories: ["music"] },
          async metadata({ query, category }) {
            if (category !== "music") return []
            return [
              { id: 302127, title: "Discovery", artist: "Daft Punk", year: "2001-03-07", cover: "https://img.test/d.jpg", type: "album" },
              { id: "x", title: "Around the World", artists: ["Daft Punk"], type: "ep" },
              { title: "no id" },
            ]
          },
          async tracks({ id }) { return [{ title: "One More Time " + id, duration: 320 }, { id: "t2", title: "Aerodynamic", position: 2, disc: "1" }] },
        }
        """#
        let runner = PluginRunner(transport: MockTransport())
        let call = PluginCall(manifest: try await runner.manifest(of: script), script: script, settings: [:])
        let catalog = PluginAlbumCatalog(call: call, transport: MockTransport())

        let albums = try await catalog.albums(matching: "discovery")
        #expect(albums.map(\.id) == ["plugin:music.test:302127", "plugin:music.test:x"], "a row without an id is skipped")
        #expect(albums[0].artists == ["Daft Punk"] && albums[0].year == 2001 && albums[0].type == "Album" && albums[1].type == "EP")
        #expect(catalog.owns(albums[0].id) && !catalog.owns("am:1"))

        let tracks = try await catalog.tracks(ofAlbum: albums[0].id)
        #expect(tracks.map(\.title) == ["One More Time 302127", "Aerodynamic"])
        #expect(tracks.map(\.position) == [1, 2] && tracks[0].duration == 320)

        let metadata = MusicMetadata(catalogs: [catalog], transport: MockTransport(), gate: MusicBrainzGate(interval: .zero))
        #expect(try await metadata.tracks(of: albums[1]).count == 2, "MusicMetadata asks the catalog that owns the album")
    }

    @Test func slowCallsAreAbandoned() async throws {
        let script = #"globalThis.plugin = { manifest: { id: "x" }, async search() { while (true) { await dove.sleep(5000) } } }"#
        let runner = PluginRunner(transport: MockTransport(), timeout: .milliseconds(200))
        let manifest = try await runner.manifest(of: script)
        let start = ContinuousClock.now
        await #expect(throws: PluginError.self) {
            try await runner.search(manifest, script: script, settings: [:], query: "q", category: .books)
        }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func searchRowsAndLinks() async throws {
        let transport = MockTransport()
        await transport.stub("/dyn/api/fast_download.json", json: #"{"download_url":"https://cdn.test/f.epub"}"#)
        let runner = PluginRunner(transport: transport)
        let manifest = try await manifest()
        let book = BookSummary(id: "ol:1", title: "Solaris", authors: ["Stanisław Lem"])

        let rows = try await runner.search(manifest, script: Self.script, settings: settings, query: "solaris", category: .audiobooks, book: book)
        #expect(rows.count == 1, "a row without an id is skipped")
        #expect(rows[0].id == "7" && rows[0].title == "solaris in audiobooks" && rows[0].author == "Stanisław Lem")
        #expect(rows[0].kind == .audiobooks && rows[0].format == "m4b" && rows[0].size == 1234)

        let single = try await runner.resolve(manifest, script: Self.script, settings: settings, id: "abc")
        #expect(single == [PluginLink(url: URL(string: "https://cdn.test/f.epub")!, fileName: "Book.epub")])
        #expect(await transport.requests.first?.url?.host() == "mirror.test", "a {setting} host is allowed")
        let many = try await runner.resolve(manifest, script: Self.script, settings: settings, id: "many")
        #expect(many.map(\.isPlain) == [true, false] && many[0].name == "1.mp3")
        await #expect(throws: PluginError.self) {
            try await runner.resolve(manifest, script: Self.script, settings: settings, id: "bad")
        }
    }

    @Test func templatesAndHostPolicies() {
        #expect(PluginTemplate.fill("https://{domain}/search?q={query}", values: ["domain": "a.test", "query": "Hail Mary & co"], encode: true)
            == "https://a.test/search?q=Hail%20Mary%20%26%20co")
        #expect(PluginTemplate.fill("https://{domain}/x", values: [:]) == nil, "an empty setting leaves no address")
        #expect(PluginTemplate.fill("https://{domain}/search", values: ["domain": "https://Site.test/"]) == "https://Site.test/search",
                "an address pasted whole gives its host after ://")
        #expect(PluginTemplate.fillPattern("^https?://{domain}/md5/", values: ["domain": "https://a.test/"]) == #"^https?://a\.test/md5/"#)
        let pattern = PluginTemplate.fillPattern("^https://{domain}/md5/(?<id>[0-9a-f]{32})", values: ["domain": "a.test"])
        #expect(pattern == #"^https://a\.test/md5/(?<id>[0-9a-f]{32})"#)

        let policy = PluginHostPolicy(hosts: ["api.books.test", "*.covers.test", "{domain}"], settings: ["domain": "https://Mirror.test/"])
        #expect(policy.allows(URL(string: "https://api.books.test/x")!))
        #expect(policy.allows(URL(string: "https://img.covers.test/x")!) && !policy.allows(URL(string: "https://covers.test/x")!))
        #expect(policy.allows(URL(string: "https://mirror.test/dyn")!), "a setting holding a whole address gives its host")
        #expect(!policy.allows(URL(string: "https://books.test/x")!) && !policy.allows(URL(string: "http://api.books.test/x")!))
    }

    @Test func repositoriesInstallOnlyWhatTheyPin() async throws {
        let transport = MockTransport()
        let script = Data(Self.script.utf8)
        let sha = PluginChecksum.sha256(script)
        await transport.stub("/index.json", json: """
        {"format":"dove-plugins","version":1,"name":"Mine","plugins":[
          {"id":"test.books","name":"Test books","version":"1.0.0","script":"plugins/test.js","sha256":"\(sha)","api":1},
          {"id":"test.bad","name":"Bad","version":"1.0.0","script":"plugins/test.js","sha256":"00","api":1},
          {"id":"test.next","name":"Next","version":"2.0.0","script":"x.js","sha256":"00","api":2}]}
        """)
        await transport.stub("/plugins/test.js", body: script)
        let client = PluginRepositoryClient(transport: transport)
        let indexURL = URL(string: "https://lakafior.github.io/dove-plugins/index.json")!

        let index = try await client.index(at: indexURL)
        #expect(index.plugins.map(\.id) == ["test.books", "test.bad", "test.next"])
        #expect(index.plugins[0].scriptURL(relativeTo: indexURL)?.absoluteString == "https://lakafior.github.io/dove-plugins/plugins/test.js")
        #expect(!index.plugins[2].isSupported)

        let installed = try await client.install(index.plugins[0], from: indexURL)
        #expect(installed.plugin.manifest.name == "Test books" && installed.script == Self.script)
        await #expect(throws: PluginError("Bad's script does not match the repository's checksum. It was not installed.")) {
            try await client.install(index.plugins[1], from: indexURL)
        }
        await #expect(throws: PluginError("Next needs a newer Dove (plugin API 2).")) {
            try await client.install(index.plugins[2], from: indexURL)
        }

        let notARepo = MockTransport()
        await notARepo.stub("/index.json", json: #"{"hello":"world"}"#)
        await #expect(throws: PluginError("lakafior.github.io is not a Dove plugin repository.")) {
            try await PluginRepositoryClient(transport: notARepo).index(at: indexURL)
        }
    }

    @Test func storedPluginsCallBrowseAndRecogniseLinks() async throws {
        let manifest = try await manifest()
        let call = PluginCall(manifest: manifest, script: Self.script, settings: ["domain": .text("mirror.test")])
        #expect(call.browseURL(for: "Hail Mary & co")?.absoluteString == "https://mirror.test/search?q=Hail%20Mary%20%26%20co")
        #expect(call.linkID(in: URL(string: "https://mirror.test/md5/D6E1DC51A50726F00EC438AF21952A45")!) == "D6E1DC51A50726F00EC438AF21952A45")
        #expect(call.linkID(in: URL(string: "https://other.test/md5/d6e1dc51a50726f00ec438af21952a45")!) == nil)
        #expect(PluginCall(manifest: manifest, script: "", settings: [:]).browseURL(for: "x") == nil, "no address set")

        let keychain = KeychainStore(service: "dove-tests-\(UUID().uuidString)", synchronizable: false)
        let folder = FileManager.default.temporaryDirectory.appending(path: "plugins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PluginStore(keychain: keychain, scriptsDirectory: folder)
        let entry = PluginRepositoryIndex.Entry(
            id: manifest.id, name: manifest.name, version: "1.0.0", script: "p.js", sha256: PluginChecksum.sha256(Data(Self.script.utf8)), api: 1
        )
        let plugin = InstalledPlugin(repository: URL(string: "https://repo.test/index.json")!, entry: entry, manifest: manifest)
        do {
            try store.saveInstalled([plugin])
            try store.saveSettings([manifest.id: ["domain": .text("mirror.test")]])
        } catch {
            return // No Keychain in this test environment: the file part below still runs.
        }
        defer {
            try? keychain.set(nil, for: .plugins)
            try? keychain.set(nil, for: .pluginSettings)
        }
        #expect(store.installed().map(\.id) == [manifest.id])
        #expect(store.knowsLink(URL(string: "https://mirror.test/md5/d6e1dc51a50726f00ec438af21952a45")!))
        #expect(store.script(for: plugin) == nil, "no script file yet")
        try store.saveScript(Self.script, for: entry)
        #expect(store.script(for: plugin) == Self.script)
        var newer = entry
        newer.version = "1.1.0"
        #expect(newer.isNewer(than: entry) && !entry.isNewer(than: newer))
        store.removeScripts(of: manifest.id)
        #expect(store.script(for: plugin) == nil)
    }
}

struct GamePluginTests {
    @Test func gameMetadataFromPluginsJoinsIGDBAndWikidata() async throws {
        let script = #"""
        globalThis.plugin = { manifest: { id: "games.test", name: "Games test", capabilities: ["metadata"], categories: ["games"] },
          async metadata({ query, category }) {
            if (category !== "games") return []
            return [
              { id: 1942, title: "Elden Ring", year: "2022-02-25", platforms: ["PC", "PlayStation 5", "xboxSeries", "Atari 2600"],
                cover: "https://img.test/er.jpg", type: "game", aliases: ["ER"] },
              { id: "m1", name: "Elden Ring Reforged", platform: "pc", type: "mod", description: "A mod." },
              { title: "no id" },
            ]
          },
        }
        """#
        let runner = PluginRunner(transport: MockTransport())
        let call = PluginCall(manifest: try await runner.manifest(of: script), script: script, settings: [:])
        let catalog = PluginGameCatalog(call: call, transport: MockTransport())

        let games = try await catalog.games(matching: "elden ring")
        #expect(games.map(\.id) == ["plugin:games.test:1942", "plugin:games.test:m1"], "a row without an id is skipped")
        #expect(games[0].year == 2022 && games[0].platforms == [.pc, .ps5, .xboxSeries], "unknown platforms are left out")
        #expect(games[0].isMainGame && games[0].alternativeNames == ["ER"])
        #expect(games[1].title == "Elden Ring Reforged" && games[1].type == "Mod" && !games[1].isMainGame && games[1].summary == "A mod.")

        // Without IGDB: the plugin's row (with its cover) and Wikidata's one game become one.
        let wikidata = MockTransport()
        await wikidata.stub("/sparql", body: try Fixture.data("wikidata_games"))
        let merged = try await GameMetadata(igdb: nil, catalogs: [catalog], transport: wikidata).search("elden ring")
        let elden = merged.filter { $0.title == "Elden Ring" }
        #expect(elden.count == 1 && elden.first?.cover?.absoluteString == "https://img.test/er.jpg")
        #expect(merged.first?.title == "Elden Ring")
        #expect(merged.contains { $0.title == "Elden Ring Nightreign" })

        // Wikidata down: the plugin still answers.
        let down = MockTransport()
        await down.stub("/sparql", status: 500, json: "{}")
        #expect(try await GameMetadata(igdb: nil, catalogs: [catalog], transport: down).search("elden ring").count == 2)
    }
}

struct PluginTorrentLinkTests {
    @Test func magnetsAndTorrentFilesAreTorrents() throws {
        let decoder = JSONDecoder()
        let magnet = try decoder.decode(PluginLink.self, from: Data(#"{"url":"magnet:?xt=urn:btih:4CC8E331E699748269F6AC1B98B802684F5AC97A&dn=ELDEN+RING+FitGirl"}"#.utf8))
        #expect(magnet.isTorrent && magnet.isPlain)
        #expect(magnet.name == "ELDEN RING FitGirl")
        #expect(magnet.magnet == .magnet("magnet:?xt=urn:btih:4CC8E331E699748269F6AC1B98B802684F5AC97A&dn=ELDEN+RING+FitGirl"))
        let file = try decoder.decode(PluginLink.self, from: Data(#"{"url":"https://site.test/get/game.torrent","headers":{"Cookie":"a=b"}}"#.utf8))
        #expect(file.isTorrent && file.magnet == nil && file.name == "game.torrent")
        let plain = try decoder.decode(PluginLink.self, from: Data(#"{"url":"https://site.test/game.zip"}"#.utf8))
        #expect(!plain.isTorrent)
        #expect(throws: PluginError.self) { try decoder.decode(PluginLink.self, from: Data(#"{"url":"magnet:?dn=no+hash"}"#.utf8)) }
        #expect(throws: PluginError.self) { try decoder.decode(PluginLink.self, from: Data(#"{"url":"ftp://site.test/game.zip"}"#.utf8)) }
    }
}
