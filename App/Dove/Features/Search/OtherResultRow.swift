import DoveKit
import SwiftUI

/// One release from Dove's own indexers, found by name: software, music, books or anything else.
/// Torrents show which debrid services already have them (⚡), like the source list.
struct OtherResultRow: View {
    let group: StreamGroup
    let isBusy: Bool
    let downloadOnly: Bool
    let onAdd: (() -> Void)?

    private var kind: ContentKind { group.contentKind }

    /// Formats a book or audiobook release names (EPUB, M4B…).
    private var formats: [BookFileFormat] {
        kind == .books || kind == .audiobooks ? BookRelease(group).formats : []
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
                    ForEach(formats, id: \.self) { format in
                        Text(format.displayName)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
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
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                SourceOriginLine(group: group)
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
