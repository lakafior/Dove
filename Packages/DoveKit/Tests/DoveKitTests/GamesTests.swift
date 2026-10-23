import Foundation
import Testing
@testable import DoveKit

struct GameGuessTests {
    @Test(arguments: [
        // No-Intro / Redump: article moved back, region and revision read, extension tells the platform.
        ("Legend of Zelda, The - A Link to the Past (USA) (Rev 1).sfc", "The Legend of Zelda - A Link to the Past", GamePlatform?.some(.snes)),
        ("Pokemon - Emerald Version (USA, Europe).gba", "Pokemon - Emerald Version", .gameBoyAdvance),
        ("Metal Gear Solid (USA) (Disc 1) (v1.1).chd", "Metal Gear Solid", nil),
        ("Super Mario Odyssey [0100000000010000][v0].nsp", "Super Mario Odyssey", .nintendoSwitch),
        // Scene and repacks: PC unless the name says otherwise.
        ("Elden.Ring.Shadow.of.the.Erdtree-RUNE", "Elden Ring Shadow of the Erdtree", .pc),
        ("Baldurs.Gate.3.v4.1.1.3767641-GOG", "Baldurs Gate 3", .pc),
        ("Cyberpunk 2077 v2.1 - GOG", "Cyberpunk 2077", .pc),
        ("Red Dead Redemption 2 [v 1436.28 + DLCs] [FitGirl Repack]", "Red Dead Redemption 2", .pc),
        ("Elden Ring - Deluxe Edition [FitGirl Repack]", "Elden Ring", .pc),
        ("The.Witcher.3.Wild.Hunt.Complete.Edition-GOG", "The Witcher 3 Wild Hunt", .pc),
        ("The_Legend_of_Zelda_Tears_of_the_Kingdom_NSW-VENOM", "The Legend of Zelda Tears of the Kingdom", .nintendoSwitch),
        ("God.of.War.PS4-DUPLEX", "God of War", .ps4),
    ])
    func readsTitleAndPlatform(name: String, title: String, platform: GamePlatform?) {
        let guess = GameGuess(releaseName: name)
        #expect(guess.title == title)
        #expect(guess.platform == platform)
    }

    @Test func readsRegionVersionEditionAndYear() {
        let zelda = GameGuess(releaseName: "Legend of Zelda, The - A Link to the Past (USA) (Rev 1).sfc")
        #expect(zelda.region == "USA" && zelda.version == "Rev 1")
        #expect(GameGuess(releaseName: "Baldurs.Gate.3.v4.1.1.3767641-GOG").version == "4.1.1.3767641")
        #expect(GameGuess(releaseName: "Red Dead Redemption 2 [v 1436.28 + DLCs] [FitGirl Repack]").version == "1436.28")
        #expect(GameGuess(releaseName: "Elden Ring - Deluxe Edition [FitGirl Repack]").edition == "Deluxe Edition")
        #expect(GameGuess(releaseName: "Fallout.3.GOTY-GOG").edition == "Game of the Year Edition")
        #expect(GameGuess(releaseName: "Cyberpunk 2077 v2.1 - GOG").year == nil, "a number in the title is not a year")
        #expect(GameGuess(releaseName: "Doom (1993) [GOG]").year == 1993)
        #expect(GameGuess(releaseName: "Elden.Ring-RUNE").key == GameGuess(releaseName: "ELDEN RING [FitGirl Repack]").key)
    }

    @Test func collectionsAreNotMatchedFileByFile() {
        #expect(GameGuess.isCollection(name: "No-Intro - Nintendo - Super Nintendo Entertainment System (2024)"))
        #expect(GameGuess.isCollection(name: "SNES.Romset.Complete"))
        #expect(GameGuess.isCollection(name: "Some Pack", gameFiles: 120))
        #expect(!GameGuess.isCollection(name: "Super Metroid (Japan, USA) (En,Ja).sfc"))
    }
}

struct GamePlatformTests {
    @Test func platformsFromFilesNamesCategoriesAndServices() {
        #expect(GamePlatform(fileName: "Mario Kart 64 (USA).z64") == .n64)
        #expect(GamePlatform(fileName: "game.iso") == nil, "ISOs: the name decides")
        #expect(GamePlatform(releaseName: "Gran.Turismo.4.PS2.ISO") == .ps2)
        #expect(GamePlatform(releaseName: "Halo.3.XBOX360-COMPLEX") == .xbox360)
        #expect(GamePlatform(releaseName: "Halo Infinite Xbox Series X") == .xboxSeries)
        #expect(GamePlatform(releaseName: "Mario Kart Wii U") == .wiiU)
        #expect(GamePlatform(releaseName: "Elden.Ring-RUNE") == nil)
        #expect(GamePlatform(newznabCategory: 4050) == .pc)
        #expect(GamePlatform(newznabCategory: 1180) == .ps4)
        #expect(GamePlatform(newznabCategory: 1000) == nil)
        #expect(GamePlatform(serviceName: "PC (Microsoft Windows)") == .pc)
        #expect(GamePlatform(serviceName: "Super Nintendo Entertainment System") == .snes)
        #expect(GamePlatform(serviceName: "Xbox Series X|S") == .xboxSeries)
        #expect(GamePlatform(serviceName: "Atari 2600") == nil)
    }
}

struct GameKindTests {
    @Test(arguments: [
        ("Cyberpunk 2077 v2.1 - GOG", ContentKind.games),
        ("Some.Game-FitGirl.Repack", .games),
        ("Gran.Turismo.4.PS2.ISO", .games),
        ("No-Intro SNES Romset", .games),
        ("Super Metroid (Japan, USA) (En,Ja).sfc", .games),
        ("Zelda.nsp", .games),
        ("ubuntu-24.04-desktop-amd64.iso", .software),
        ("Ubuntu 24.04 Desktop amd64", .software),
        ("Adobe Photoshop 2024 v25.1 x64", .software),
    ])
    func classifies(name: String, kind: ContentKind) {
        #expect(ContentClassifier.classify(name: name, files: []) == kind)
    }

    @Test func anISOUnderAGamesNameIsAGame() {
        let files = [LibraryFile(id: "1", name: "Gran Turismo 4/GT4.iso", size: 4_000_000_000)]
        #expect(ContentClassifier.classify(name: "Gran.Turismo.4.PS2-GRP", files: files) == .games)
        #expect(ContentClassifier.classify(name: "Windows 11 24H2", files: files) == .software)
    }

    @Test func categories() {
        #expect(ContentKind(newznabCategory: 4050) == .games)
        #expect(ContentKind(newznabCategory: 1080) == .games)
        #expect(ContentKind(newznabCategory: 4010) == .software)
        #expect(AddCategory(newznabCategory: 4050) == .games)
        #expect(AddCategory(newznabCategory: 1180) == .games)
        #expect(AddCategory(releaseName: "Elden.Ring-RUNE.nzb") == .games)
        #expect(NewznabCategory.games.ids == [1000, 4050])
        #expect(SearchCategory.games.contentKind == .games)
        #expect(LibraryFolderLayout.folderName(.games) == "Games")
    }
}

struct GameMetadataTests {
    private let credentials = GameMetadata.IGDBCredentials(clientID: " client ", clientSecret: "secret\n")

    private func stubTwitch(_ transport: MockTransport) async {
        await transport.stub("/oauth2/token", json: #"{"access_token":"tok123","expires_in":5587808,"token_type":"bearer"}"#)
    }

    @Test func searchesIGDBWithAnAppToken() async throws {
        let transport = MockTransport()
        await stubTwitch(transport)
        await transport.stub("/v4/games", body: try Fixture.data("igdb_games"))
        let metadata = GameMetadata(igdb: credentials, usesWikidata: false, transport: transport, tokens: TwitchTokens())
        let games = try await metadata.search("zelda link to the past")

        let zelda = try #require(games.first)
        #expect(zelda.id == "igdb:1026" && zelda.title == "The Legend of Zelda: A Link to the Past")
        #expect(zelda.year == 1991)
        #expect(zelda.platforms == [.snes, .gameBoyAdvance, .wii])
        #expect(zelda.cover?.absoluteString == "https://images.igdb.com/igdb/image/upload/t_cover_big_2x/co3vzn.jpg")
        #expect(zelda.genres == ["Adventure", "Role-playing (RPG)"])
        #expect(zelda.alternativeNames.contains("ALttP"))
        #expect(games[1].title.hasSuffix("Four Swords"), "the bundle after the game")

        let requests = await transport.requests
        let token = try #require(requests.first)
        #expect(token.httpMethod == "POST")
        let tokenQuery = URLComponents(url: token.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(tokenQuery.contains(URLQueryItem(name: "client_id", value: "client")))
        #expect(tokenQuery.contains(URLQueryItem(name: "grant_type", value: "client_credentials")))
        let search = try #require(requests.last)
        #expect(search.httpMethod == "POST")
        #expect(search.value(forHTTPHeaderField: "Client-ID") == "client")
        #expect(search.value(forHTTPHeaderField: "Authorization") == "Bearer tok123")
        let body = String(decoding: search.httpBody ?? Data(), as: UTF8.self)
        #expect(body.hasPrefix(#"search "zelda link to the past"; fields name,"#))
        #expect(body.contains("where version_parent = null;"))

        _ = try await metadata.search("elden ring")
        #expect(await transport.requests.filter { $0.url?.path == "/oauth2/token" }.count == 1, "the token is kept")
    }

    @Test func aRejectedTokenIsRenewedOnceAndBadCredentialsAreNamed() async throws {
        let transport = MockTransport()
        await stubTwitch(transport)
        await transport.stub("/v4/games", status: 401, json: "{}")
        await transport.stub("/v4/games", body: try Fixture.data("igdb_games"))
        let metadata = GameMetadata(igdb: credentials, usesWikidata: false, transport: transport, tokens: TwitchTokens())
        #expect(try await metadata.search("elden ring").first?.title == "Elden Ring")
        #expect(await transport.requests.filter { $0.url?.path == "/oauth2/token" }.count == 2)

        let wrong = MockTransport()
        await wrong.stub("/oauth2/token", status: 403, json: #"{"status":403,"message":"invalid client secret"}"#)
        let bad = GameMetadata(igdb: credentials, usesWikidata: false, transport: wrong, tokens: TwitchTokens())
        await #expect(throws: BackendError.api(message: "Twitch did not accept the Client ID and secret.")) {
            try await bad.validateIGDB()
        }
    }

    @Test func searchesWikidataWithoutAKey() async throws {
        let transport = MockTransport()
        await transport.stub("/sparql", body: try Fixture.data("wikidata_games"))
        let games = try await GameMetadata(igdb: nil, transport: transport).search("elden ring")

        #expect(games.map(\.title).prefix(2) == ["Elden Ring", "Elden Ring Nightreign"])
        let elden = try #require(games.first)
        #expect(elden.id == "wd:Q64826862" && elden.year == 2022 && elden.cover == nil)
        #expect(elden.platforms.starts(with: [.pc, .ps4, .xboxOne, .ps5, .xboxSeries]))
        #expect(games.first { $0.title == "Cyberpunk 2" }?.year == nil, "an unknown date is no year")

        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Dove") == true)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
        #expect(query.contains(#"mwapi:srsearch "elden ring haswbstatement:P31=Q7889""#))
    }

    @Test func bothSourcesMergeAndOneFailingIsFine() async throws {
        let transport = MockTransport()
        await stubTwitch(transport)
        await transport.stub("/v4/games", body: try Fixture.data("igdb_games"))
        await transport.stub("/sparql", body: try Fixture.data("wikidata_games"))
        let games = try await GameMetadata(igdb: credentials, transport: transport, tokens: TwitchTokens()).search("elden ring")
        #expect(games.filter { $0.title == "Elden Ring" }.map(\.id) == ["igdb:119133"], "one row, IGDB's")
        #expect(games.contains { $0.id == "wd:Q131435228" }, "a game only Wikidata knows is added")
        #expect(games.first?.title == "Elden Ring")

        let igdbDown = MockTransport()
        await stubTwitch(igdbDown)
        await igdbDown.stub("/v4/games", status: 500, json: "{}")
        await igdbDown.stub("/sparql", body: try Fixture.data("wikidata_games"))
        #expect(try await GameMetadata(igdb: credentials, transport: igdbDown, tokens: TwitchTokens()).search("elden ring").first?.id == "wd:Q64826862")
    }

    @Test func matchesLibraryGuessesOrNothing() throws {
        let games = try JSONDecoder().decode([IGDBGame].self, from: Fixture.data("igdb_games")).map(\.gameSummary)
        let zelda = GameGuess(releaseName: "Legend of Zelda, The - A Link to the Past (USA) (Rev 1).sfc")
        #expect(GameMatcher.best(games, for: zelda)?.id == "igdb:1026", "names match without punctuation")
        #expect(GameMatcher.best(games, for: GameGuess(releaseName: "Elden.Ring-RUNE"))?.id == "igdb:119133")
        let erdtree = GameGuess(releaseName: "Elden.Ring.Shadow.of.the.Erdtree-RUNE")
        #expect(GameMatcher.best(games, for: erdtree)?.id == "igdb:267001", "the add-on itself when listed")
        let erdtreeOnly = games.filter { $0.id != "igdb:267001" }
        #expect(GameMatcher.best(erdtreeOnly, for: erdtree)?.id == "igdb:119133", "else the game it starts with")
        let wrongPlatform = GameGuess(releaseName: "Elden.Ring.NSW-GRP")
        #expect(GameMatcher.best(games, for: wrongPlatform) == nil, "a platform the game is not on")
        #expect(GameMatcher.best(games, for: GameGuess(releaseName: "Hollow Knight [GOG]")) == nil)
        #expect(GameMatcher.best(games, for: GameGuess(title: "ALttP"))?.id == "igdb:1026", "alternative names count")
    }
}

struct GameReleaseTests {
    private let zelda = GameSummary(id: "igdb:1026", title: "The Legend of Zelda: A Link to the Past", alternativeNames: ["ALttP"])
    private let elden = GameSummary(id: "igdb:119133", title: "Elden Ring")

    @Test func releasesOfAGame() {
        #expect(GameMatcher.matches("Legend of Zelda, The - A Link to the Past (USA).sfc", zelda))
        #expect(GameMatcher.matches("Legend.of.Zelda.A.Link.to.the.Past.SNES-GRP", zelda), "no article")
        #expect(!GameMatcher.matches("Legend of Zelda, The - A Link Between Worlds (USA).3ds", zelda))
        #expect(GameMatcher.matches("ELDEN RING [FitGirl Repack]", elden))
        #expect(GameMatcher.matches("Elden.Ring.Shadow.of.the.Erdtree-RUNE", elden), "with its DLC")
        #expect(!GameMatcher.matches("Elden Ring Nightreign-RUNE", GameSummary(id: "x", title: "Elden Ring Shadow of the Erdtree")))
        #expect(zelda.indexerQuery == "Legend of Zelda A Link to the Past")
        #expect(GameMatcher.rank([elden, zelda], for: "the legend of zelda a link to the past").first == zelda)
    }

    @Test func releasePlatforms() {
        #expect(GamePlatform.of(release: "Some Game", category: 1180) == .ps4)
        #expect(GamePlatform.of(release: "Some.Game.NSW-GRP", category: 1000) == .nintendoSwitch)
        #expect(GamePlatform.of(release: "Some.Game-RUNE", category: 4050) == .pc)
        #expect(GamePlatform.of(release: "Some.Game-RUNE", category: nil) == nil)
    }

    @Test func hintsKeepTheGame() throws {
        let hint = AddedHint(releaseName: "Elden.Ring-RUNE", game: elden)
        #expect(!hint.isEmpty)
        let decoded = try JSONDecoder().decode(AddedHint.self, from: JSONEncoder().encode(hint))
        #expect(decoded.game == elden)
        #expect(CredentialKey.igdbClientSecret.sensitivity == .secret)
    }
}

struct WikidataGameTests {
    @Test func portsUnderTheSameNameKeepTheDatedOneAndCompilationsSinkBelowTheGame() async throws {
        let transport = MockTransport()
        await transport.stub("/sparql", body: try Fixture.data("wikidata_games"))
        let games = try await GameMetadata(igdb: nil, transport: transport).search("zelda link to the past")
        let zelda = games.filter { $0.title == "The Legend of Zelda: A Link to the Past" }
        #expect(zelda.map(\.id) == ["wd:Q370055"], "the 1991 original, whatever came first")
        #expect(zelda.first?.year == 1991 && zelda.first?.platforms == [.snes])
        #expect(games.first?.id == "wd:Q370055")
        #expect(games.first { $0.id == "wd:Q1358804" }?.type == "Compilation")
    }
}

struct GameLibraryTests {
    private func item(_ id: String, _ name: String, added: TimeInterval, backend: BackendID = .torBox, hint: AddedHint? = nil) -> ShelfItem {
        ShelfItem(item: LibraryItem(id: id, backend: backend, name: name, size: 10, status: .ready, addedAt: Date(timeIntervalSince1970: added)), hint: hint)
    }

    private let elden = GameSummary(id: "igdb:119133", title: "Elden Ring", year: 2022, platforms: [.pc, .ps5])

    @Test func groupsReleasesOfOneGameAndKeepsCollectionsApart() {
        let items = [
            item("1", "Elden.Ring-RUNE", added: 1),
            item("2", "ELDEN RING [FitGirl Repack]", added: 3),
            item("3", "Elden.Ring.PS5-DUPLEX", added: 2),
            item("4", "No-Intro SNES Romset", added: 4),
            item("5", "Super Metroid (Japan, USA) (En,Ja).sfc", added: 0),
            item("6", "ubuntu-24.04-desktop-amd64.iso", added: 5),
        ]
        #expect(items.map(\.kind) == [.games, .games, .games, .games, .games, .software])
        let games = LibraryShelf.games(items, matches: [GameGuess(releaseName: "Elden.Ring-RUNE").key: elden])
        #expect(games.map(\.name) == ["No-Intro SNES Romset", "Elden Ring", "Super Metroid"], "newest first")
        let ring = games[1]
        #expect(ring.id == "game:igdb:119133" && ring.items.count == 3)
        #expect(ring.platforms == [.pc, .ps5], "platforms held, from the names (scene groups and repackers are PC)")
        #expect(games[0].isCollection && games[0].game == nil)
        #expect(games[2].platforms == [.snes] && games[2].year == nil)
        #expect(LibraryShelf.others(items).map(\.item.id) == ["6"], "games are not other files")
    }

    @Test func filtersAndHints() async {
        let items = [item("1", "Elden.Ring-RUNE", added: 1, backend: .offcloud), item("2", "Hollow Knight [GOG]", added: 2)]
        let games = LibraryShelf.games(items, matches: [:])
        var filter = LibraryFilter()
        filter.category = .games
        #expect(filter.apply(to: games).count == 2)
        filter.backends = [.offcloud]
        #expect(filter.apply(to: games).map(\.name) == ["Elden Ring"])
        filter = LibraryFilter()
        filter.category = .books
        #expect(filter.apply(to: games).isEmpty)
        filter.category = nil
        filter.query = "hollow"
        #expect(filter.apply(to: games).map(\.name) == ["Hollow Knight"])

        let store = MetadataStore<GameSummary>(fileURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let hinted = [item("1", "Elden.Ring-RUNE", added: 1, hint: AddedHint(releaseName: nil, game: elden))]
        let applied = await LibraryMatcher.applyGameHints(hinted, store: store)
        #expect(applied == [GameGuess(releaseName: "Elden.Ring-RUNE").key: elden])
        #expect(await LibraryMatcher.applyGameHints(hinted, store: store).isEmpty, "recorded once")

        // A repack is a PC release; a hint for a Game Boy Color game of the same name is not applied.
        #expect(GameGuess(releaseName: "Hollow Knight - Silksong [FitGirl Repack]").platform == .pc)
        let homebrew = GameSummary(id: "plugin:lb:432714", title: "Hollow Knight: Silk Song", year: 2021, platforms: [.gameBoyColor], type: "Homebrew")
        let wrong = [item("3", "Hollow Knight - Silksong [FitGirl Repack]", added: 3, hint: AddedHint(releaseName: nil, game: homebrew))]
        #expect(await LibraryMatcher.applyGameHints(wrong, store: store).isEmpty)
    }
}

struct GameFolderTests {
    @Test func gamesAreFiledByPlatformThenGame() {
        let zelda = GameSummary(id: "igdb:1026", title: "The Legend of Zelda: A Link to the Past", platforms: [.snes, .gameBoyAdvance])
        let rom = LibraryFolderLayout.placement(
            kind: .games, game: zelda, itemName: "Legend of Zelda, The - A Link to the Past (USA).sfc",
            fileName: "Legend of Zelda, The - A Link to the Past (USA).sfc", singleFile: true
        )
        #expect(rom == .init(folder: "Games/SNES/The Legend of Zelda - A Link to the Past", fileName: "Legend of Zelda, The - A Link to the Past (USA).sfc"),
                "the ROM keeps its name; the folder takes the game's")

        let repack = LibraryFolderLayout.placement(
            kind: .games, itemName: "Elden Ring - Deluxe Edition [FitGirl Repack]", fileName: "setup-fitgirl-01.bin", singleFile: false
        )
        #expect(repack == .init(folder: "Games/PC/Elden Ring", fileName: "setup-fitgirl-01.bin"), "repackers release PC games")

        let switchOnly = GameSummary(id: "igdb:2", title: "Super Mario Odyssey", platforms: [.nintendoSwitch])
        let fromGame = LibraryFolderLayout.placement(kind: .games, game: switchOnly, itemName: "Super Mario Odyssey", fileName: "smo.bin", singleFile: true)
        #expect(fromGame.folder == "Games/Switch/Super Mario Odyssey", "a game on one platform")

        let unknown = LibraryFolderLayout.placement(kind: .games, itemName: "Some Game", fileName: "game.iso", singleFile: true)
        #expect(unknown.folder == "Games/Other Platforms/Some Game")

        let set = LibraryFolderLayout.placement(kind: .games, itemName: "No-Intro SNES Romset", fileName: "Super Metroid (USA).sfc", singleFile: false)
        #expect(set.folder == "Games/SNES/No-Intro SNES Romset", "a collection keeps its name")
    }

    @Test func gameFoldersReadBackWithTheirPlatform() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "games-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = root.appending(path: "Games/SNES/The Legend of Zelda - A Link to the Past/Zelda (USA).sfc")
        let other = root.appending(path: "Games/Other Platforms/Some Game/game.iso")
        for url in [rom, other] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let items = try await FolderBackend(directory: root).items()
        let zelda = try #require(items.first { $0.id == "folder:Games/SNES/The Legend of Zelda - A Link to the Past" })
        #expect(zelda.name == "The Legend of Zelda - A Link to the Past [SNES]" && zelda.kindHint == .games)
        let guess = try #require(ShelfItem(item: zelda).gameGuess)
        #expect(guess.title == "The Legend of Zelda - A Link to the Past" && guess.platform == .snes)
        #expect(items.first { $0.id == "folder:Games/Other Platforms/Some Game" }?.name == "Some Game")
        #expect(GamePlatform(releaseName: "Doom [PC]") == .pc)
        #expect(GamePlatform(releaseName: "Halo [Xbox 360]") == .xbox360)
    }
}

struct GameMergeTests {
    @Test func theOriginalBeatsLaterPortsAndSoundtracksSink() {
        let port = GameSummary(id: "wd:1", title: "The Legend of Zelda: A Link to the Past", year: 2002, platforms: [.gameBoyAdvance])
        let original = GameSummary(id: "plugin:lb:2", title: "The Legend of Zelda: A Link to the Past", year: 1991, platforms: [.snes], cover: nil)
        let merged = GameMatcher.merge([], [port, original])
        #expect(merged.map(\.id) == ["plugin:lb:2"], "the earliest dated one")

        let soundtrack = GameSummary(id: "s:2", title: "Hollow Knight Official Soundtrack", type: "Soundtrack")
        let game = GameSummary(id: "s:1", title: "Hollow Knight Silksong")
        #expect(!soundtrack.isMainGame)
        #expect(GameMatcher.rank([soundtrack, game], for: "hollow knight").first == game)
    }

    /// LaunchBox's 2021 Game Boy Color homebrew "Hollow Knight: Silk Song" took the place of the 2025 game (from GOG
    /// and Wikidata) as "the earliest one", so a FitGirl repack showed as a Game Boy Color game from 2021.
    @Test func anEarlierHomebrewOfTheSameNameDoesNotReplaceTheGame() throws {
        let homebrew = GameSummary(id: "plugin:lb:432714", title: "Hollow Knight: Silk Song", year: 2021, platforms: [.gameBoyColor], type: "Homebrew")
        let gog = GameSummary(id: "plugin:gog:1", title: "Hollow Knight: Silksong", year: 2025, platforms: [.pc], type: "Main Game")
        let wikidata = GameSummary(id: "wd:Q63294487", title: "Hollow Knight: Silksong", year: 2025, platforms: [.pc, .nintendoSwitch])
        #expect(!homebrew.isMainGame)
        let results = GameMatcher.rank(GameMatcher.merge([], [homebrew, gog, wikidata]), for: "Hollow Knight - Silksong")
        let guess = GameGuess(releaseName: "Hollow Knight - Silksong [FitGirl Repack]")
        let best = try #require(GameMatcher.best(results, for: guess))
        #expect(best.year == 2025 && best.platforms.contains(.pc))
        #expect(results.contains { $0.id == homebrew.id }, "the homebrew stays findable")
    }
}
