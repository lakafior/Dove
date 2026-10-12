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
