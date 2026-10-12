import Foundation
import Testing
@testable import DoveKit

struct ReleaseParserTests {
    @Test func remuxWithDolbyVisionAndTrueHD() {
        let t = ReleaseParser.parse("Dune.2021.UHD.BluRay.2160p.TrueHD.Atmos.7.1.DV.HEVC.REMUX-FraMeSToR.mkv")
        #expect(t.resolution == "2160p")
        #expect(t.quality == "BluRay REMUX")
        #expect(t.encode == "HEVC")
        #expect(t.visualTags.contains("DV"))
        #expect(t.audioTags.contains("TrueHD"))
        #expect(t.audioTags.contains("Atmos"))
        #expect(t.releaseGroup == "FraMeSToR")
    }

    @Test func webDLWithDDPlusAndHDR10Plus() {
        let t = ReleaseParser.parse("Severance (2022) S01E01 (1080p DS4K ATVP Webrip DV HDR10+ DDP5.1 Atmos)")
        #expect(t.resolution == "1080p")
        #expect(t.quality == "WEBRip")
        #expect(t.visualTags.contains("HDR10+"))
        #expect(t.audioTags.contains("DD+"))
        #expect(t.seasons == [1])
        #expect(t.episodes == [1])
        #expect(!t.seasonPack)
    }

    @Test func hyphenatedSourcesSurviveSpaceSeparatedNames() {
        #expect(ReleaseParser.parse("Severance S01 2160p ATVP WEB-DL DDP5 1 Atmos DV MKV x265-TEPES").quality == "WEB-DL")
        #expect(ReleaseParser.parse("Movie 2020 1080p Blu-ray x264").quality == "BluRay")
        #expect(ReleaseParser.parse("Movie 2020 1080p WEB-Rip x264").quality == "WEBRip")
    }

    @Test func h265WithDotsIsHEVC() {
        #expect(ReleaseParser.parse("Dune.2021.1080p.HMAX.WEB-DL.DDP5.1.Atmos.DV.H.265-FLUX.mp4").encode == "HEVC")
        #expect(ReleaseParser.parse("Dune.2021.1080p.HMAX.WEB-DL.DDP5.1.Atmos.H.264-FLUX").encode == "AVC")
        #expect(ReleaseParser.parse("Show.S01E01.1080p.WEB.AV1.Opus-GRP").encode == "AV1")
    }

    @Test(arguments: [
        ("Severance S01 1080p BluRay REMUX AVC DTS-HD MA 5 1-TRiToN", [1], [Int](), true),
        ("Severance.S01E01.Good.News.About.Hell.1080p", [1], [1], false),
        ("Show.S02E01-E03.720p.HDTV", [2], [1, 2, 3], false),
        ("Scissione.1x01.Buone.Notizie.ITA-ENG.1080p", [1], [1], false),
        ("Show.S01-S03.1080p.BluRay", [1, 2, 3], [], true),
        ("Severance (Season 1) BDRip 1080p", [1], [], true),
        ("Dune.2021.2160p.WEB-DL", [], [], false),
    ])
    func seasonsAndEpisodes(name: String, seasons: [Int], episodes: [Int], pack: Bool) {
        let t = ReleaseParser.parse(name)
        #expect(t.seasons == seasons)
        #expect(t.episodes == episodes)
        #expect(t.seasonPack == pack)
    }

    @Test func polishReleasesAreRecognised() {
        #expect(ReleaseParser.parse("Backrooms.2026.PLSUB.2160p.iT.WEB-DL").languages.contains("PL"))
        #expect(ReleaseParser.parse("Film.2024.1080p.WEB-DL.Lektor.PL.DD5.1").languages.first == "PL")
        #expect(ReleaseParser.parse("3.Body.Problem.S01.Eng.Fre.Ger.Ita.Por.Spa.Chi.Hin.Pol.Ukr.2160p").languages.contains("PL"))
    }
}

struct StreamGroupTests {
    private func candidates() async throws -> [StreamCandidate] {
        let transport = MockTransport()
        await transport.stub("api/v1/search", body: try Fixture.data("aiostreams_search_episode"))
        let client = AIOStreamsSearch(origin: URL(string: "https://aio.example")!, uuid: "u", password: "p", transport: transport)
        return try await client.search(type: .series, id: "tt11280740:1:1").candidates
    }

    @Test func sameInfoHashFromSeveralServicesIsOneRow() {
        let hash = "3133f1ac4b86226ca105e69b1c1374ef552380b5"
        let groups = StreamGroup.group([
            StreamCandidate(id: "a", kind: .debrid, title: "Show.S01E01.1080p.WEB-DL.mkv", infoHash: hash, service: "offcloud", cached: true),
            StreamCandidate(id: "b", kind: .debrid, title: "Show.S01E01.1080p.WEB-DL.mkv", infoHash: hash.uppercased(), service: "torbox", cached: false),
            StreamCandidate(id: "c", kind: .debrid, title: "Show.S01E01.2160p.mkv", infoHash: "ff", service: "realdebrid", cached: true),
        ])
        #expect(groups.count == 2)
        #expect(groups[0].availability.map(\.service) == ["offcloud", "torbox"])
        #expect(groups[0].cachedBackends() == [.offcloud])
        #expect(groups[0].traits.resolution == "1080p")
    }

    @Test func seasonPackIsDetectedFromTheFolder() async throws {
        let groups = StreamGroup.group(try await candidates())
        let pack = try #require(groups.first { $0.folderName?.hasPrefix("Severance S01 1080p BluRay REMUX") == true })
        #expect(pack.isSeasonPack(1))
        #expect(!pack.isSeasonPack(2))
        #expect(!pack.isSeriesPack)
        #expect(PackScope.season(1).matches(pack))
        let single = try #require(groups.first { $0.primary.service == "nzbdav" })
        #expect(!single.isPack)
        #expect(!PackScope.season(1).matches(single))
    }

    @Test func multiSeasonFolderIsASeriesPack() {
        let group = StreamGroup.group([
            StreamCandidate(id: "a", kind: .debrid, title: "Show.S01E01.mkv", size: 1, folderName: "Show.S01-S04.1080p.BluRay", folderSize: 100, infoHash: "aa")
        ])[0]
        #expect(group.packSeasons == [1, 2, 3, 4])
        #expect(group.isSeriesPack)
        #expect(PackScope.series.matches(group))
    }

    @Test func appleTVWarnings() {
        let remux = StreamGroup.group([StreamCandidate(id: "a", kind: .debrid, title: "Dune.2021.2160p.BluRay.REMUX.TrueHD.Atmos.7.1.DV.HEVC")])[0]
        #expect(remux.appleTVWarnings.count == 1)
        let web = StreamGroup.group([StreamCandidate(id: "b", kind: .debrid, title: "Dune.2021.2160p.WEB-DL.DDP5.1.Atmos.DV.HEVC")])[0]
        #expect(web.appleTVWarnings.isEmpty)
        let av1 = StreamGroup.group([StreamCandidate(id: "c", kind: .debrid, title: "Show.S01E01.1080p.WEB.AV1")])[0]
        #expect(av1.appleTVWarnings.first?.hasPrefix("AV1") == true)
    }

    @Test func serviceNamesMapToBackends() {
        #expect(BackendID(service: "realdebrid") == .realDebrid)
        #expect(BackendID(service: "TorBox") == .torBox)
        #expect(BackendID(service: "easynews") == nil)
    }
}
