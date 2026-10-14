import Foundation

/// An item's files in sections for its screen: by season when the files are episodes, else by folder.
public struct FileGroup: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case season(Int)
        case folder(String)
        /// Files outside any season or folder (the release root, extras, `.nfo`).
        case other
    }

    public let kind: Kind
    /// In episode order for seasons, by name otherwise.
    public var files: [LibraryFile]

    public var id: String {
        switch kind {
        case .season(let number): "season:\(number)"
        case .folder(let path): "folder:\(path)"
        case .other: "other"
        }
    }

    public var title: String {
        switch kind {
        case .season(0): "Specials"
        case .season(let number): "Season \(number)"
        case .folder(let path): path
        case .other: "Other files"
        }
    }

    public var size: Int64 { files.compactMap(\.size).reduce(0, +) }

    /// The name to show in this section: the folder the section stands for is left out.
    public func displayName(of file: LibraryFile) -> String {
        switch kind {
        case .season, .other: (file.name as NSString).lastPathComponent
        case .folder(let path): String(file.name.dropFirst(path.count + 1))
        }
    }
}

public enum FileGroups {
    /// Seasons when any video file is an episode (other files go to "Other files"), folders when the paths
    /// have them, and one group otherwise. Seasons in order with specials last; folders by name, root files last.
    public static func groups(_ files: [LibraryFile], release: MediaGuess) -> [FileGroup] {
        let byName = files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var seasons: [Int: [(episode: Int, file: LibraryFile)]] = [:]
        var rest: [LibraryFile] = []
        for file in byName {
            if FileKind.isVideo(file.name), !FileKind.isSample(file.name),
               let located = SeriesLayout.locate(file.name, in: release), let episode = located.episodes.first {
                seasons[located.season, default: []].append((episode, file))
            } else {
                rest.append(file)
            }
        }

        if !seasons.isEmpty {
            let groups = seasons.keys
                .sorted { ($0 == 0 ? Int.max : $0) < ($1 == 0 ? Int.max : $1) }
                .map { season in
                    // Stable sort keeps name order among files of the same episode.
                    FileGroup(kind: .season(season), files: seasons[season]!.enumerated()
                        .sorted { ($0.element.episode, $0.offset) < ($1.element.episode, $1.offset) }
                        .map(\.element.file))
                }
            return rest.isEmpty ? groups : groups + [FileGroup(kind: .other, files: rest)]
        }

        let folders = Dictionary(grouping: byName) { ($0.name as NSString).deletingLastPathComponent }
        guard folders.keys.contains(where: { !$0.isEmpty }), folders.count > 1 || folders[""] == nil else {
            return byName.isEmpty ? [] : [FileGroup(kind: .other, files: byName)]
        }
        return folders.keys.filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { FileGroup(kind: .folder($0), files: folders[$0]!) }
            + (folders[""].map { [FileGroup(kind: .other, files: $0)] } ?? [])
    }
}
