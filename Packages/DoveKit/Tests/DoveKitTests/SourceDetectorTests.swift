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
