import DoveKit
import SwiftUI

/// Search › Other: how Dove's results outside movies and series are searched and shown.
enum SearchScope: String, CaseIterable {
    case media
    case other

    var label: String {
        switch self {
        case .media: "Movies & series"
        case .other: "Other"
        }
    }
}

/// One release from Dove's own indexers, found by name: software, music, books or anything else.
/// Torrents show which debrid services already have them (⚡), like the source list.
struct OtherResultRow: View {
    let group: StreamGroup
    let isBusy: Bool
    let downloadOnly: Bool
    let onAdd: (() -> Void)?

    private var kind: ContentKind {
        group.category.map(ContentKind.init(newznabCategory:)) ?? .other
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title)
                    .font(.subheadline)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    if let size = group.size {
                        Text(size.formatted(.byteCount(style: .file))).monospacedDigit()
                    }
                    Text(kind.displayName)
                    if let seeders = group.seeders {
                        Label("\(seeders)", systemImage: "arrow.up").labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(group.availability, id: \.service) { availability in
                        HStack(spacing: 2) {
                            if availability.cached == true {
                                Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                            }
                            Text(availability.displayName)
                        }
                        .foregroundStyle(availability.cached == true ? .primary : .secondary)
                    }
                    if !group.indexers.isEmpty {
                        Text("via " + group.indexers.joined(separator: " · ")).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let onAdd {
                Button(action: onAdd) {
                    Group {
                        if isBusy { ProgressView() } else { Image(systemName: downloadOnly ? "arrow.down" : "plus") }
                    }
                    .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
                .accessibilityLabel(downloadOnly ? "Download only" : "Add to library")
            }
        }
        .padding(.vertical, 2)
    }
}
