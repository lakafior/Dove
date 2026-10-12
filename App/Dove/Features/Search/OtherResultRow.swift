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
struct OtherResultRow: View {
    let candidate: StreamCandidate
    let isBusy: Bool
    let downloadOnly: Bool
    let onAdd: (() -> Void)?

    private var kind: ContentKind {
        candidate.category.map(ContentKind.init(newznabCategory:)) ?? .other
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.title)
                    .font(.subheadline)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    if let size = candidate.size {
                        Text(size.formatted(.byteCount(style: .file))).monospacedDigit()
                    }
                    Text(kind.displayName)
                    if let seeders = candidate.seeders {
                        Label("\(seeders)", systemImage: "arrow.up").labelStyle(.titleAndIcon)
                    }
                    if !candidate.label.isEmpty { Text("via " + candidate.label).lineLimit(1) }
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

extension ContentKind {
    var symbol: String {
        switch self {
        case .video: "film"
        case .music: "music.note"
        case .books: "book"
        case .software: "shippingbox"
        case .other: "doc"
        }
    }
}
