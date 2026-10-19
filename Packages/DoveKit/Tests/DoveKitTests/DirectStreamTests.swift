import Foundation
import Testing
@testable import DoveKit

struct DirectStreamTests {
    private func streams() async throws -> [StreamCandidate] {
        let transport = MockTransport()
        let manifest = try JSONDecoder().decode(StremioManifest.self, from: Fixture.data("stremio_aiostreams_manifest"))
        let addon = StremioAddon(manifestURL: URL(string: "https://direct.example/cfg/manifest.json")!, manifest: manifest, transport: transport)
        await transport.stub("stream/movie/tt0111161.json", body: try Fixture.data("stremio_streams_direct"))
        return try await addon.streams(type: .movie, id: "tt0111161")
    }

    @Test func plainLinksAreHTTPAndDebridResolveLinksAreNot() async throws {
        let streams = try await streams()
        #expect(streams.map(\.kind) == [.unknown, .http, .http, .http, .debrid, .debrid])
        #expect(streams[1].sourceType == .web)
    }

    @Test func theExistingDebridFixtureStaysPlayOnly() async throws {
        let transport = MockTransport()
        let manifest = try JSONDecoder().decode(StremioManifest.self, from: Fixture.data("stremio_aiostreams_manifest"))
        let addon = StremioAddon(manifestURL: URL(string: "https://a.example/manifest.json")!, manifest: manifest, transport: transport)
        await transport.stub("stream/series/tt11280740:1:1.json", body: try Fixture.data("stremio_streams_episode"))
        let streams = try await addon.streams(type: .series, id: "tt11280740:1:1")
        #expect(streams.allSatisfy { $0.kind == .debrid })
        #expect(streams.allSatisfy { $0.directFile == nil })
    }

    @Test func fileNameDropsTheSortTextAfterABar() async throws {
        let stream = try await streams()[1]
        #expect(stream.title == "The.Shawshank.Redemption.1994.1080p.BluRay.H264.AAC-RARBG.mp4")
        #expect(stream.size == 2_813_203_579)
    }

    @Test func directFilesExcludePlaylistsAndKeepHeaders() async throws {
        let streams = try await streams()
        let plain = try #require(streams[1].directFile)
        #expect(plain.isPlain)
        #expect(plain.fileName == "The.Shawshank.Redemption.1994.1080p.BluRay.H264.AAC-RARBG.mp4")
        #expect(streams[2].directFile == nil)
        #expect(streams[2].headers["Cookie"] == "Policy=x")
        let withHeaders = try #require(streams[3].directFile)
        #expect(!withHeaders.isPlain)
        #expect(withHeaders.request.value(forHTTPHeaderField: "Referer") == "https://api.example/")
    }

    @Test func refPicksTheSameFileFromAFreshAnswer() async throws {
        let streams = try await streams()
        let ref = try #require(StreamFileRef(candidate: streams[1], type: .movie, streamID: "tt0111161"))
        #expect(ref.source == "aiostreamsfortheweebsstable.midnightignite.me.00000000-000")
        #expect(ref.fileName == "The.Shawshank.Redemption.1994.1080p.BluRay.H264.AAC-RARBG.mp4")
        #expect(ref.pick(from: streams)?.url == streams[1].url)

        var renamed = streams
        renamed[1].title = "Other name.mp4"
        #expect(ref.pick(from: renamed)?.url == streams[1].url)
        #expect(ref.pick(from: [streams[3]]) == nil)
        #expect(StreamFileRef(candidate: streams[4], type: .movie, streamID: "tt0111161") == nil)
    }

    @Test func recordKeepsItsStreamRef() throws {
        let ref = StreamFileRef(source: "com.example", type: .series, streamID: "tt1:1:2", fileName: "E02.mkv", bingeGroup: "g", size: 5)
        let record = DownloadRecord(backend: nil, stream: ref, itemID: "stream:com.example", fileID: "tt1:1:2/E02.mkv", name: "E02.mkv")
        let decoded = try JSONDecoder().decode(DownloadRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.stream == ref)
        #expect(decoded.plugin == nil)
    }

    @Test func plainHTTPRefusalReadsAsAHint() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorAppTransportSecurityRequiresSecureConnection)
        #expect(DownloadManager.reason(for: error).contains("plain HTTP"))
    }

    @Test func directLinksSitBetweenReadyAndUncachedAndHeaderLinksLast() async throws {
        let groups = StreamGroup.group(try await streams())
        let ranking = SourceRanking(debrids: [.torBox])
        #expect(ranking.tier(for: groups[1]) == .direct)
        #expect(ranking.tier(for: groups[2]) == .limited)
        #expect(ranking.tier(for: groups[3]) == .limited)
        let uncached = StreamGroup.group([StreamCandidate(id: "t", kind: .p2p, title: "A.2160p.mkv", infoHash: "h")])[0]
        let order = ranking.sorted([groups[3], uncached, groups[1]])
        #expect(order.map(\.id) == [groups[1].id, uncached.id, groups[3].id])
    }

    @Test func bitrateComesFromTheAddonsText() {
        #expect(StremioText.bitrate(in: "🎞️ 1080p • MP4 • ~2.6 Mbps") == 2.6)
        #expect(StremioText.bitrate(in: "◈  15 GB · 33.9 ᴹᵇᵖˢ") == 33.9)
        #expect(StremioText.bitrate(in: "AAC 5.1 128kbps") == nil)
    }

    @Test func starvedReEncodesSinkWithinTheirRung() {
        let starved = StreamCandidate(id: "a#0", kind: .http, title: "Movie.2160p.mp4", url: URL(string: "https://x.example/a.mp4"), bitrate: 3)
        let fine = StreamCandidate(id: "a#1", kind: .http, title: "Movie.1080p.mp4", url: URL(string: "https://x.example/b.mp4"), bitrate: 6)
        let unknown = StreamCandidate(id: "a#2", kind: .http, title: "Movie.720p.mp4", url: URL(string: "https://x.example/c.mp4"))
        let order = SourceRanking().sorted(StreamGroup.group([starved, fine, unknown]))
        #expect(order.map(\.id) == ["a#1", "a#2", "a#0"])
    }
}
