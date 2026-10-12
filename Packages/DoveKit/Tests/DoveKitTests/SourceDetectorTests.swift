import Foundation
import Testing
@testable import DoveKit

struct SourceDetectorTests {
    @Test func magnetLink() {
        let magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=test"
        #expect(SourceDetector.detect("  \(magnet)\n") == .magnet(magnet))
    }

    @Test func bareInfoHashBecomesMagnet() {
        let hash = "0123456789ABCDEF0123456789ABCDEF01234567"
        #expect(SourceDetector.detect(hash) == .magnet("magnet:?xt=urn:btih:\(hash.lowercased())"))
    }

    @Test func torrentURL() {
        let source = SourceDetector.detect("https://example.org/files/linux.iso.torrent")
        #expect(source?.kind == .torrent)
    }

    @Test func nzbByExtension() {
        #expect(SourceDetector.detect("https://indexer.example/get/abc.nzb")?.kind == .nzb)
    }

    @Test func nzbByNewznabGet() {
        #expect(SourceDetector.detect("https://indexer.example/api?t=get&id=abc&apikey=secret")?.kind == .nzb)
    }

    @Test func otherHTTPLinkIsHoster() {
        #expect(SourceDetector.detect("https://1fichier.com/?abcdef")?.kind == .hoster)
    }

    @Test(arguments: ["", "   ", "Gra o tron", "ftp://example.org/file", "not a url at all"])
    func nonSourcesReturnNil(_ input: String) {
        #expect(SourceDetector.detect(input) == nil)
    }
}

struct SourceInTextTests {
    @Test func magnetInsideAMessage() {
        let text = "check this out: magnet:?xt=urn:btih:1a07d876aaaebe797c21eff39df7436d2f739b7a&dn=Ubuntu+24.04 enjoy"
        #expect(SourceDetector.firstSource(in: text) == .magnet("magnet:?xt=urn:btih:1a07d876aaaebe797c21eff39df7436d2f739b7a&dn=Ubuntu+24.04"))
    }

    @Test func linkInsideAMessage() {
        let source = SourceDetector.firstSource(in: "Grab it from https://files.example.org/show.s01e01.torrent today")
        #expect(source == .torrentURL(URL(string: "https://files.example.org/show.s01e01.torrent")!))
    }

    @Test func bareHashInsideText() {
        #expect(SourceDetector.firstSource(in: "hash: 1A07D876AAAEBE797C21EFF39DF7436D2F739B7A")?.kind == .torrent)
    }

    @Test func plainTextHasNoSource() {
        #expect(SourceDetector.firstSource(in: "Diuna część druga") == nil)
    }

    @Test func displayNames() {
        #expect(Source.magnet("magnet:?xt=urn:btih:abc&dn=Ubuntu+24.04").displayName == "Ubuntu 24.04")
        #expect(Source.magnet("magnet:?xt=urn:btih:ABC").displayName == "ABC")
        #expect(Source.torrentFile(data: Data(), filename: "a.torrent").displayName == "a.torrent")
        #expect(Source.hosterURL(URL(string: "https://host.example/f/1")!).displayName == "host.example/f/1")
    }
}
