import Foundation
import Testing
@testable import DoveKit

struct SourceRankingTests {
    private func group(
        _ id: String,
        _ title: String,
        size: Int64 = 10,
        service: String? = nil,
        cached: Bool? = nil
    ) -> StreamGroup {
        StreamGroup.group([
            StreamCandidate(id: id, kind: .debrid, title: title, size: size, infoHash: id, service: service, cached: cached)
        ])[0]
    }

    private func order(_ groups: [StreamGroup], debrids: [BackendID]) -> [String] {
        SourceRanking(debrids: debrids).sorted(groups).map(\.id)
    }

    @Test func appleTVFriendlyBeatsCachedAndQuality() {
        let av1 = group("av1", "Movie.2024.2160p.WEB-DL.DV.AV1-GRP", service: "torbox", cached: true)
        let hevc = group("hevc", "Movie.2024.1080p.WEB-DL.x265-GRP")
        #expect(order([av1, hevc], debrids: [.torBox]) == ["hevc", "av1"])
    }

    @Test func cachedBeatsHigherResolution() {
        let uhd = group("uhd", "Movie.2024.2160p.BluRay.REMUX.HEVC-GRP")
        let cached = group("fhd", "Movie.2024.1080p.BluRay.x264-GRP", service: "torbox", cached: true)
        #expect(order([uhd, cached], debrids: [.torBox]) == ["fhd", "uhd"])
    }

    @Test func cacheOnAServiceTheUserLacksDoesNotCount() {
        let uhd = group("uhd", "Movie.2024.2160p.BluRay.REMUX.HEVC-GRP")
        let elsewhere = group("fhd", "Movie.2024.1080p.BluRay.x264-GRP", service: "premiumize", cached: true)
        #expect(order([elsewhere, uhd], debrids: [.torBox]) == ["uhd", "fhd"])
    }

    @Test func qualityOrdersTheRest() {
        let groups = [
            group("720", "Movie.2024.720p.WEB-DL.x264-GRP"),
            group("sdr", "Movie.2024.2160p.WEB-DL.HEVC-GRP"),
            group("dv", "Movie.2024.2160p.WEB-DL.DV.HEVC-GRP"),
            group("remux", "Movie.2024.2160p.BluRay.REMUX.DV.HEVC-GRP"),
        ]
        #expect(order(groups, debrids: [.torBox]) == ["remux", "dv", "sdr", "720"])
    }

    @Test func sizeBreaksTies() {
        let small = group("small", "Movie.2024.1080p.WEB-DL.x264-A", size: 2)
        let big = group("big", "Movie.2024.1080p.WEB-DL.x264-B", size: 8)
        #expect(order([small, big], debrids: [.torBox]) == ["big", "small"])
    }

    @Test func refusedNameSinksToTheBottomWhenRealDebridIsTheOnlyDebrid() {
        let webdl = group("webdl", "Movie.2024.2160p.WEB-DL.DV.HEVC-GRP", service: "realdebrid", cached: true)
        let bluray = group("bluray", "Movie.2024.720p.BluRay.x265-GRP")
        #expect(order([webdl, bluray], debrids: [.realDebrid]) == ["bluray", "webdl"])
        #expect(SourceRanking(debrids: [.realDebrid]).realDebridWarning(for: webdl) == "Real-Debrid refuses this release name")
    }

    @Test func refusedNameCostsLittleWhenAnotherDebridCanTakeIt() {
        let webdl = group("webdl", "Movie.2024.2160p.WEB-DL.HEVC-GRP")
        let bluray = group("bluray", "Movie.2024.720p.BluRay.x265-GRP")
        let ranking = SourceRanking(debrids: [.realDebrid, .torBox])
        // Same tier otherwise: the refused one goes below, before quality is compared.
        #expect(ranking.sorted([webdl, bluray]).map(\.id) == ["bluray", "webdl"])
        #expect(ranking.realDebridWarning(for: webdl) == "Real-Debrid refuses this name; another service takes it")
    }

    @Test func refusedNameDoesNotMatterWhenAnotherServiceHasItCached() {
        let webdl = group("webdl", "Movie.2024.2160p.WEB-DL.HEVC-GRP", service: "torbox", cached: true)
        let ranking = SourceRanking(debrids: [.realDebrid, .torBox])
        #expect(ranking.realDebridWarning(for: webdl) == nil)
        #expect(SourceRanking(debrids: [.torBox]).realDebridWarning(for: webdl) == nil, "no Real-Debrid account")
    }

    @Test func recommendedIsTheDefaultSortAndOldSavesKeepTheirs() throws {
        #expect(SourceFilter().sort == .recommended)
        let saved = Data(#"{"selected":{},"appleTVFriendly":false,"sort":"sizeDescending"}"#.utf8)
        #expect(try JSONDecoder().decode(SourceFilter.self, from: saved).sort == .sizeDescending)
    }
}
