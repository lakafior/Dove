import Foundation
import Testing
@testable import DoveKit

struct ExternalPlayerTests {
    private let link = PlayEntry(
        url: URL(string: "https://dl.example/dld/abc/Show+Name.S01E01.mkv?token=x&y=1")!,
        filename: "Show - S01E01.mkv"
    )
    private let second = PlayEntry(url: URL(string: "https://dl.example/2.mkv")!, filename: "Show - S01E02.mkv")
    private let encoded = "https%3A%2F%2Fdl.example%2Fdld%2Fabc%2FShow%2BName.S01E01.mkv%3Ftoken%3Dx%26y%3D1"

    @Test func infuseTakesEveryEntryWithItsFileName() {
        let url = ExternalPlayer.infuse.link(for: [link, second])?.absoluteString
        #expect(url == "infuse://x-callback-url/play?url=\(encoded)&filename=Show%20-%20S01E01.mkv"
            + "&url=https%3A%2F%2Fdl.example%2F2.mkv&filename=Show%20-%20S01E02.mkv")
    }

    @Test func schemePlayersGetTheFirstEntryEncoded() {
        #expect(ExternalPlayer.vlc.link(for: [link, second])?.absoluteString
            == "vlc-x-callback://x-callback-url/stream?url=\(encoded)")
        #expect(ExternalPlayer.outplayer.link(for: [link])?.absoluteString
            == "outplayer://x-callback-url/play?url=\(encoded)")
        #expect(ExternalPlayer.senPlayer.link(for: [link])?.absoluteString
            == "senplayer://x-callback-url/play?url=\(encoded)")
        #expect(ExternalPlayer.vidHub.link(for: [link])?.absoluteString
            == "open-vidhub://x-callback-url/open?url=\(encoded)")
    }

    @Test func nPlayerPrefixesTheLinksOwnScheme() {
        #expect(ExternalPlayer.nPlayer.link(for: [second])?.absoluteString == "nplayer-https://dl.example/2.mkv")
    }

    @Test func kodiHasNoLink() {
        #expect(ExternalPlayer.kodi.link(for: [link]) == nil)
    }

    @Test func customTemplateFillsPlaceholders() {
        let raw = ExternalPlayer.custom.link(for: [second], customTemplate: " myplayer://{url} ")
        #expect(raw?.absoluteString == "myplayer://https://dl.example/2.mkv")
        let query = ExternalPlayer.custom.link(for: [second], customTemplate: "x://play?u={encodedUrl}&n={filename}")
        #expect(query?.absoluteString == "x://play?u=https%3A%2F%2Fdl.example%2F2.mkv&n=Show%20-%20S01E02.mkv")
    }

    @Test func customTemplateWithoutALinkIsRefused() {
        #expect(ExternalPlayer.custom.link(for: [second], customTemplate: "x://play?n={filename}") == nil)
        #expect(ExternalPlayer.custom.link(for: [second], customTemplate: "") == nil)
    }

    @Test func noEntriesNoLink() {
        #expect(ExternalPlayer.infuse.link(for: []) == nil)
        #expect(ExternalPlayer.vlc.link(for: []) == nil)
    }

    @Test func onlyInfuseAndKodiTakePlaylists() {
        #expect(ExternalPlayer.allCases.filter(\.takesPlaylist) == [.infuse, .kodi])
    }
}
