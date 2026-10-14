import Foundation
import Testing
@testable import DoveKit

struct SourceFilterTests {
    private let groups = StreamGroup.group([
        StreamCandidate(id: "1", kind: .debrid, title: "Show.S01E01.2160p.WEB-DL.DDP5.1.Atmos.DV.HEVC.PL-GRP", infoHash: "a", service: "torbox", cached: true),
        StreamCandidate(id: "2", kind: .debrid, title: "Show.S01E01.1080p.BluRay.REMUX.TrueHD.Atmos.AVC-GRP", size: 30, infoHash: "b", service: "realdebrid", cached: true),
        StreamCandidate(id: "3", kind: .debrid, title: "Show.S01E01.1080p.WEB.AV1-GRP", size: 2, infoHash: "c", service: "offcloud", cached: false),
        StreamCandidate(id: "4", kind: .debrid, title: "Show.S01E01.720p.HDTV.x264", size: 1, infoHash: "d"),
    ])

    @Test func noFilterKeepsEverything() {
        #expect(SourceFilter().apply(to: groups).count == 4)
        #expect(!SourceFilter().isActive)
    }

    @Test func valuesInADimensionAreAlternatives() {
        var filter = SourceFilter()
        filter.sort = .addon
        filter.toggle("2160p", in: .resolution)
        filter.toggle("720p", in: .resolution)
        #expect(filter.apply(to: groups).map(\.id) == ["a", "d"])
    }

    @Test func dimensionsCombine() {
        var filter = SourceFilter()
        filter.toggle("1080p", in: .resolution)
        filter.toggle("HEVC", in: .encode)
        #expect(filter.apply(to: groups).isEmpty)
        filter.toggle("AVC", in: .encode)
        #expect(filter.apply(to: groups).map(\.id) == ["b"])
    }

    @Test func sdrMeansNoHDRTags() {
        var filter = SourceFilter()
        filter.sort = .sizeDescending
        filter.toggle("SDR", in: .video)
        #expect(filter.apply(to: groups).map(\.id) == ["b", "c", "d"])
        filter = SourceFilter()
        filter.toggle("DV", in: .video)
        #expect(filter.apply(to: groups).map(\.id) == ["a"])
    }

    @Test func languageCodesMatchAIOStreamsNames() {
        var filter = SourceFilter()
        filter.toggle("PL", in: .language)
        #expect(filter.apply(to: groups).map(\.id) == ["a"])
        #expect(LanguageName.code("Polish") == "PL")
        #expect(LanguageName.code("Dual Audio") == "MULTi")
    }

    @Test func cachedOnService() {
        var filter = SourceFilter()
        filter.toggle("Real-Debrid", in: .cached)
        #expect(filter.apply(to: groups).map(\.id) == ["b"])
    }

    @Test func appleTVFriendlyDropsAV1AndTrueHDAtmos() {
        var filter = SourceFilter()
        filter.sort = .addon
        filter.appleTVFriendly = true
        #expect(filter.apply(to: groups).map(\.id) == ["a", "d"])
    }

    @Test func sortBySize() {
        var filter = SourceFilter()
        filter.sort = .sizeDescending
        #expect(filter.apply(to: groups).map(\.id) == ["b", "c", "d", "a"])
    }

    @Test func optionsAreOrderedAndCounted() {
        let resolutions = SourceFilter.options(for: .resolution, in: groups)
        #expect(resolutions.map(\.value) == ["2160p", "1080p", "720p"])
        #expect(resolutions.map(\.count) == [1, 2, 1])
        #expect(SourceFilter.options(for: .cached, in: groups).map(\.value) == ["Real-Debrid", "TorBox"])
    }

    @Test func roundTripsThroughJSON() throws {
        var filter = SourceFilter()
        filter.toggle("PL", in: .language)
        filter.appleTVFriendly = true
        filter.sort = .sizeAscending
        let decoded = try JSONDecoder().decode(SourceFilter.self, from: JSONEncoder().encode(filter))
        #expect(decoded == filter)
        // Filters saved before sorting existed default to largest first.
        #expect(try JSONDecoder().decode(SourceFilter.self, from: Data("{}".utf8)).sort == .sizeDescending)
    }
}

struct SourceOriginFilterTests {
    private let groups = StreamGroup.group([
        StreamCandidate(id: "1", kind: .p2p, title: "A.2023.1080p.WEB-DL", infoHash: String(repeating: "a", count: 40),
                        seeders: 5, provider: "Jackett", tracker: "TorrentLeech", isPrivate: true,
                        published: Date(timeIntervalSince1970: 2_000)),
        StreamCandidate(id: "2", kind: .debrid, title: "B.2023.1080p.WEB-DL", infoHash: String(repeating: "b", count: 40),
                        seeders: 50, provider: "AIOStreams", addon: "Torrentio", tracker: "1337x", isPrivate: false,
                        published: Date(timeIntervalSince1970: 1_000)),
        StreamCandidate(id: "newznab:geek:3", kind: .usenet, title: "C.2023.1080p.WEB-DL",
                        nzbURL: URL(string: "https://geek.example/3.nzb"), provider: "NZBgeek"),
    ])

    @Test func typePrivacyProviderAndTrackerAreFilterable() {
        #expect(SourceFilter.options(for: .type, in: groups).map(\.value) == ["Torrent", "Usenet"])
        #expect(SourceFilter.options(for: .privacy, in: groups).map(\.value) == ["Private", "Public"])
        #expect(Set(SourceFilter.options(for: .provider, in: groups).map(\.value)) == ["Jackett", "Torrentio", "NZBgeek"])
        #expect(Set(SourceFilter.options(for: .tracker, in: groups).map(\.value)) == ["TorrentLeech", "1337x"])

        var filter = SourceFilter()
        filter.sort = .addon
        filter.toggle("Private", in: .privacy)
        #expect(filter.apply(to: groups).map(\.title) == ["A.2023.1080p.WEB-DL"])

        filter.reset()
        filter.toggle("Usenet", in: .type)
        #expect(filter.apply(to: groups).map(\.title) == ["C.2023.1080p.WEB-DL"])
    }

    @Test func sortsBySeedersAndAge() {
        var filter = SourceFilter()
        filter.sort = .seeders
        #expect(filter.apply(to: groups).map(\.title) == ["B.2023.1080p.WEB-DL", "A.2023.1080p.WEB-DL", "C.2023.1080p.WEB-DL"])
        filter.sort = .newest
        #expect(filter.apply(to: groups).first?.title == "A.2023.1080p.WEB-DL")
    }

    @Test func groupsSayWhereTheyCameFrom() {
        #expect(groups[0].origins == [["Jackett", "TorrentLeech"]])
        #expect(groups[1].origins == [["AIOStreams", "Torrentio", "1337x"]])
        #expect(groups[0].isPrivate == true && groups[1].isPrivate == false && groups[2].isPrivate == nil)
    }
}
