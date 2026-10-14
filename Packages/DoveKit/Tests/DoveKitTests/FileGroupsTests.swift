import Testing
@testable import DoveKit

struct FileGroupsTests {
    private func files(_ names: [String]) -> [LibraryFile] {
        names.enumerated().map { LibraryFile(id: String($0.offset), name: $0.element) }
    }

    @Test func episodesGoToSeasonsInEpisodeOrder() {
        let release = ReleaseParser.guess("Lost.Complete.Series.1080p")
        let groups = FileGroups.groups(files([
            "Lost/Season 2/Lost.S02E10.mkv", "Lost/Season 1/Lost.S01E02.mkv", "Lost/Season 2/Lost.S02E01.mkv",
            "Lost/Season 1/Lost.S01E01.mkv", "Lost/Specials/Lost.S00E01.mkv", "Lost/Extras/Making of.mkv", "Lost/info.nfo",
        ]), release: release)
        #expect(groups.map(\.title) == ["Season 1", "Season 2", "Specials", "Other files"])
        #expect(groups[1].files.map(\.name) == ["Lost/Season 2/Lost.S02E01.mkv", "Lost/Season 2/Lost.S02E10.mkv"])
        #expect(groups[0].displayName(of: groups[0].files[0]) == "Lost.S01E01.mkv")
        #expect(groups[3].files.count == 2)
    }

    @Test func foldersWhenThereAreNoEpisodes() {
        let groups = FileGroups.groups(files(["CD2/track 01.flac", "CD1/track 01.flac", "cover.jpg"]),
                                       release: ReleaseParser.guess("Album.2020.FLAC"))
        #expect(groups.map(\.title) == ["CD1", "CD2", "Other files"])
        #expect(groups[0].displayName(of: groups[0].files[0]) == "track 01.flac")
    }

    @Test func oneGroupForFlatOrSingleFolderLists() {
        let release = ReleaseParser.guess("Movie.2020.1080p")
        #expect(FileGroups.groups(files(["Movie.2020.1080p.mkv", "Movie.nfo"]), release: release).map(\.title) == ["Other files"])
        #expect(FileGroups.groups(files(["Movie/Movie.mkv", "Movie/Movie.srt"]), release: release).map(\.title) == ["Movie"])
        #expect(FileGroups.groups([], release: release).isEmpty)
    }
}
