import DoveKit
import SwiftUI

/// Where a release comes from: torrent or Usenet, private tracker, seeders, age, and who found it
/// ("AIOStreams › Torrentio › 1337x", "Jackett › TorrentLeech").
struct SourceOriginLine: View {
    let group: StreamGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Label(group.sourceType.displayName, systemImage: group.sourceType.symbol)
                if group.isPrivate == true {
                    Label("Private", systemImage: "key.fill")
                        .foregroundStyle(.orange)
                }
                if let seeders = group.seeders {
                    Label("\(seeders)", systemImage: "person.2.fill")
                        .monospacedDigit()
                        .foregroundStyle(seeders == 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
                if let published = group.published {
                    Label(Self.age(since: published), systemImage: "clock")
                }
            }
            if !origins.isEmpty {
                Label(origins, systemImage: "magnifyingglass")
                    .lineLimit(2)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(CompactLabelStyle())
    }

    /// Up to three paths, then how many more.
    private var origins: String {
        let paths = group.origins.map { $0.map { $0.replacingOccurrences(of: ",", with: ", ") }.joined(separator: " › ") }
        let shown = paths.prefix(3).joined(separator: " · ")
        return paths.count > 3 ? shown + " · +\(paths.count - 3)" : shown
    }

    /// "5h", "3d", "2mo", "1y".
    static func age(since date: Date, now: Date = .now) -> String {
        let hours = max(0, now.timeIntervalSince(date) / 3600)
        if hours < 1 { return "<1h" }
        if hours < 48 { return "\(Int(hours))h" }
        let days = hours / 24
        if days < 60 { return "\(Int(days))d" }
        if days < 365 { return "\(Int(days / 30))mo" }
        return "\(Int(days / 365))y"
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension SourceType {
    var symbol: String {
        switch self {
        case .torrent: "point.3.connected.trianglepath.dotted"
        case .usenet: "newspaper"
        case .debridLink: "link"
        case .web: "globe"
        }
    }
}
