import Foundation
import Testing
@testable import DoveKit

struct SourceRequestTests {
    private let gb: Int64 = 1_000_000_000
    private var groups: [StreamGroup] {
        StreamGroup.group([
            StreamCandidate(id: "1", kind: .debrid, title: "Show.S01E01.2160p.WEB-DL.DDP5.1.Atmos.DV.HEVC.PL-GRP", size: 12 * gb, infoHash: "a", service: "torbox", cached: true),
            StreamCandidate(id: "2", kind: .debrid, title: "Show.S01E01.2160p.BluRay.REMUX.DV.HEVC.DTS-HD.PL-GRP", size: 60 * gb, infoHash: "b", service: "realdebrid", cached: true),
            StreamCandidate(id: "3", kind: .debrid, title: "Show.S01E01.2160p.WEB-DL.DV.HEVC.DDP5.1.PL-GRP", size: 9 * gb, infoHash: "c", service: "offcloud", cached: false),
            StreamCandidate(id: "4", kind: .debrid, title: "Show.S01E01.1080p.WEB.H264-GRP", size: 3 * gb, infoHash: "d"),
        ])
    }

    private func request(
        wanted: [SourceRequest.Dimension: [String]] = [:],
        avoided: [SourceRequest.Dimension: [String]] = [:],
        max: Double? = nil, min: Double? = nil, cached: Bool = false, sort: String? = nil,
        text: String = "4K Dolby Vision 2160p x264 Atmos Bananas 8K smallest cached 20 GB"
    ) -> SourceRequest {
        SourceRequest(text: text, wanted: wanted, avoided: avoided, maxSizeGB: max, minSizeGB: min,
                      cachedOnly: cached, appleTVFriendly: false, sort: sort, in: groups)
    }

    @Test func wantsAvoidsAndSizeCombine() {
        // "2160p DV without Atmos under 20 GB, Polish audio"
        let r = request(wanted: [.resolution: ["4K"], .video: ["Dolby Vision"], .language: ["Polish"]],
                        avoided: [.audio: ["Atmos"]], max: 20, text: "2160p DV without Atmos under 20 GB, Polish audio")
        #expect(r.wanted[.resolution] == ["2160p"])
        #expect(r.wanted[.video] == ["DV"])
        #expect(r.wanted[.language] == ["PL"])
        #expect(r.apply(to: groups).map(\.id) == ["c"])
    }

    @Test func unknownValuesAreDroppedNotGuessed() {
        let r = request(wanted: [.resolution: ["8K"], .audio: ["Bananas"], .encode: ["x264"]])
        #expect(r.wanted[.resolution] == nil)
        #expect(r.wanted[.audio] == nil)
        #expect(r.wanted[.encode] == ["AVC"])
        #expect(r.apply(to: groups).map(\.id) == ["d"])
    }

    @Test func cachedOnlyAndSortBySize() {
        let r = request(cached: true, sort: "smallest")
        #expect(r.sort == .sizeAscending)
        #expect(r.apply(to: groups).map(\.id) == ["a", "b"])
    }

    @Test func minimumSizeWantsAKnownSize() {
        #expect(request(min: 50).apply(to: groups).map(\.id) == ["b"])
        #expect(request().isEmpty)
        #expect(!request(min: 50).isEmpty)
    }

    @Test func vocabularyListsTheListsValuesFirst() {
        let vocabulary = SourceRequest.vocabulary(for: groups)
        #expect(vocabulary[.resolution]?.prefix(2) == ["2160p", "1080p"])
        #expect(vocabulary[.resolution]?.contains("720p") == true)
        #expect(vocabulary[.resolution]?.contains("Unknown") == false)
    }

    @Test func summaryAndModelCriteria() {
        let grouped = SourceRequest.grouped([("resolution", "4K"), ("hdr", "DV"), ("Language", "Polish"), ("mood", "happy")])
        #expect(grouped.keys.sorted { $0.rawValue < $1.rawValue } == [.language, .resolution, .video])
        let r = request(wanted: grouped, avoided: [.audio: ["Atmos"]], max: 20, text: "4K DV, Polish, no Atmos, under 20 GB")
        #expect(r.summary == "2160p · DV · PL · no Atmos · ≤ 20 GB")
    }

    @Test func valuesTheWordsDoNotMentionAreDropped() {
        // The model added AAC for "Polish audio", and cached/sorting nobody asked for.
        let r = request(wanted: [.language: ["PL"], .audio: ["AAC"], .video: ["DV"]], cached: true, sort: "largest",
                        text: "Polish audio, advanced")
        #expect(r.wanted == [.language: ["PL"]])
        #expect(!r.cachedOnly)
        #expect(r.sort == nil)
        #expect(request(max: 20, text: "small files please").maxSize == nil)
        // The model gave both bounds for "under 90 GB": only the one the words name stays.
        let both = request(max: 90, min: 90, text: "4K DV under 90 GB")
        #expect(both.maxSize == 90_000_000_000 && both.minSize == nil)
        let between = request(max: 90, min: 40, text: "between 40 and 90 GB, over 40 GB, under 90 GB")
        #expect(between.maxSize != nil && between.minSize != nil)
    }

    @Test func namedLanguageIsWantedEvenWhenTheModelDropsIt() {
        let dropped = request(wanted: [.video: ["DV"]], text: "DV with Polish audio")
        #expect(dropped.wanted[.language] == ["PL"])
        let avoided = request(avoided: [.language: ["PL"]], text: "no Polish dub")
        #expect(avoided.wanted[.language] == nil)
    }
}
