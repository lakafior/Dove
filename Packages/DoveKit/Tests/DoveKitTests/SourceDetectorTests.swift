import Foundation
import Testing
@testable import DoveKit

struct SourceDetectorTests {
    @Test func openedMagnetURL() throws {
        let magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=A+B"
        #expect(SourceDetector.source(opening: try #require(URL(string: magnet))) == .magnet(magnet))
    }

    @Test func openedTorrentAndNzbFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "DoveKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let torrent = directory.appending(path: "Show.S01.torrent")
        let nzb = directory.appending(path: "Movie.NZB")
        let other = directory.appending(path: "notes.txt")
        for file in [torrent, nzb, other] { try Data([7]).write(to: file) }

        #expect(SourceDetector.source(opening: torrent) == .torrentFile(data: Data([7]), filename: "Show.S01.torrent"))
        #expect(SourceDetector.source(opening: nzb) == .nzbFile(data: Data([7]), filename: "Movie.NZB"))
        #expect(SourceDetector.source(opening: other) == nil)
        #expect(SourceDetector.source(opening: directory.appending(path: "missing.torrent")) == nil)
    }

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
        #expect(SourceDetector.sources(in: text).first == .magnet("magnet:?xt=urn:btih:1a07d876aaaebe797c21eff39df7436d2f739b7a&dn=Ubuntu+24.04"))
    }

    @Test func linkInsideAMessage() {
        let source = SourceDetector.sources(in: "Grab it from https://files.example.org/show.s01e01.torrent today").first
        #expect(source == .torrentURL(URL(string: "https://files.example.org/show.s01e01.torrent")!))
    }

    @Test func bareHashInsideText() {
        #expect(SourceDetector.sources(in: "hash: 1A07D876AAAEBE797C21EFF39DF7436D2F739B7A").first?.kind == .torrent)
    }

    @Test func plainTextHasNoSource() {
        #expect(SourceDetector.sources(in: "Diuna część druga").isEmpty)
    }

    @Test func displayNames() {
        #expect(Source.magnet("magnet:?xt=urn:btih:abc&dn=Ubuntu+24.04").displayName == "Ubuntu 24.04")
        #expect(Source.magnet("magnet:?xt=urn:btih:ABC").displayName == "ABC")
        #expect(Source.torrentFile(data: Data(), filename: "a.torrent").displayName == "a.torrent")
        #expect(Source.hosterURL(URL(string: "https://host.example/f/1")!).displayName == "host.example/f/1")
    }
}

struct SourceListTests {
    @Test func findsEveryLinkInReadingOrderOnce() {
        let hash = String(repeating: "b", count: 40)
        let text = """
        Part 1: https://1fichier.com/?aaa
        Part 2: https://1fichier.com/?bbb
        magnet:?xt=urn:btih:\(String(repeating: "a", count: 40))&dn=Show
        Again https://1fichier.com/?aaa
        nzb https://indexer.example/api?t=get&id=5&apikey=x
        hash \(hash)
        """
        let sources = SourceDetector.sources(in: text)
        #expect(sources.map(\.kind) == [.hoster, .hoster, .torrent, .nzb, .torrent])
        #expect(sources[0] == .hosterURL(URL(string: "https://1fichier.com/?aaa")!))
        #expect(sources[4] == .magnet("magnet:?xt=urn:btih:\(hash)"))
    }

    @Test func aMagnetsOwnHashIsNotCountedTwice() {
        let magnet = "magnet:?xt=urn:btih:\(String(repeating: "c", count: 40))"
        #expect(SourceDetector.sources(in: "see \(magnet) ok").count == 1)
    }

    @Test func plainTextHasNone() {
        #expect(SourceDetector.sources(in: "The Office season 3").isEmpty)
    }
}
