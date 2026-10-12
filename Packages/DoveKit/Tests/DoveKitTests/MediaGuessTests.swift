import Foundation
import Testing
@testable import DoveKit

struct MediaGuessTests {
    @Test(arguments: [
        ("Severance.S01E01.Good.News.About.Hell.1080p.BluRay.REMUX.AVC.DTS-HD.MA.5.1-TRiToN.mkv", "Severance", nil, MediaType.series, 1, 1),
        ("Dune.2021.UHD.BluRay.2160p.TrueHD.Atmos.7.1.DV.HEVC.REMUX-FraMeSToR.mkv", "Dune", 2021, .movie, nil, nil),
        ("Dune Part One 2021 2160p UHD BDRip HEVC 10bit DV HDR TrueHD", "Dune Part One", 2021, .movie, nil, nil),
        ("Severance (Season 1) BDRip 1080p", "Severance", nil, .series, 1, nil),
        ("3.Body.Problem.S01.Eng.Fre.Ger.Ita.Por.Spa.Chi.Hin.Pol.Ukr.2160p.WEBMux.DV.HEVC.Atmos-SGF", "3 Body Problem", nil, .series, 1, nil),
        ("Only.Murders.in.the.Building.S05.2160p.DSNP.WEB-DL.DV.HDR.H.265", "Only Murders in the Building", nil, .series, 5, nil),
        ("Backrooms.2026.PLSUB.2160p.iT.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-BYNDR", "Backrooms", 2026, .movie, nil, nil),
        ("1917.2019.1080p.BluRay.x264", "1917", 2019, .movie, nil, nil),
        ("Blade.Runner.2049.2017.2160p.UHD.BluRay", "Blade Runner 2049", 2017, .movie, nil, nil),
        ("Some Movie (2024).mkv", "Some Movie", 2024, .movie, nil, nil),
        ("[TGx] Show.Name.S02E03.720p.HDTV.x264", "Show Name", nil, .series, 2, 3),
        ("www.UIndex.org    -    The.Movie.2023.1080p.WEB", "The Movie", 2023, .movie, nil, nil),
        ("Scissione.1x01.Buone.Notizie.ITA-ENG.1080p", "Scissione", nil, .series, 1, 1),
        ("ubuntu-24.04.1-desktop-amd64.iso", "ubuntu-24 04 1-desktop-amd64", nil, .movie, nil, nil),
    ] as [(String, String, Int?, MediaType, Int?, Int?)])
    func guess(name: String, title: String, year: Int?, type: MediaType, season: Int?, episode: Int?) {
        let guess = ReleaseParser.guess(name)
        #expect(guess.title == title)
        #expect(guess.year == year)
        #expect(guess.type == type)
        #expect(guess.season == season)
        #expect(guess.episode == episode)
    }

    @Test func keyGroupsEpisodesAndReleases() {
        #expect(ReleaseParser.guess("Severance.S01E01.1080p").key == ReleaseParser.guess("Severance S02 2160p ATVP WEB-DL").key)
        #expect(ReleaseParser.guess("Dune.2021.2160p").key != ReleaseParser.guess("Dune.1984.1080p").key)
    }

    @Test func normalizeIgnoresPunctuationAndDiacritics() {
        #expect(MediaGuess.normalize("Marvel's Agents of S.H.I.E.L.D.") == "marvelsagentsofshield")
        #expect(MediaGuess.normalize("Amélie & Co") == "amelieandco")
    }
}
