import DoveAppCore
import DoveKit
import SwiftUI

/// A title page's suggestions, the Mac form of the iPhone's "New/Missing episodes" and "Could be better" sections:
/// aired episodes the library lacks and releases worth replacing, each with Find (the title's sources) and a way to
/// hide it (`LibraryReview`). Never adds anything by itself.
struct MacReviewSection: View {
    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router
    let title: LibraryTitle
    /// With IMDb IDs once the detail has loaded; sources need them.
    let media: MediaSummary?
    var files: [ShelfItem.ID: [LibraryFile]] = [:]

    var body: some View {
        let review = model.review.review(of: title, files: files)
        let gaps = review.new + review.missing
        if !gaps.isEmpty || !review.weak.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !gaps.isEmpty { gapsRow(gaps, isNew: !review.new.isEmpty) }
                ForEach(review.weak, id: \.self) { spot in weakRow(spot) }
            }
            .padding(12)
            .frame(maxWidth: 760, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        }
    }

    private func gapsRow(_ gaps: [Episode], isNew: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isNew ? "sparkles.tv" : "exclamationmark.triangle")
                .foregroundStyle(isNew ? Color.accentColor : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(isNew ? "New episodes" : "Missing episodes").fontWeight(.semibold)
                Text(LibraryReview.label(gaps, schedule: model.review.schedule(for: title)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            findButton
            Button("Hide These") { model.review.dismissEpisodes(of: title, gaps) }
                .help("They come back only if newer episodes air.")
        }
        .controlSize(.small)
    }

    private func weakRow(_ spot: TitleReview.WeakSpot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.circle").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("Could be better: \(spot.season.map { "Season \($0), " } ?? "")\(spot.quality.label ?? "unknown quality")")
                    .fontWeight(.semibold)
                Text(spot.quality.weaknesses.map(Self.explain).joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            findButton
            Button("Keep What I Have") { model.review.dismissQuality(of: title, spot.quality) }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var findButton: some View {
        if let media, model.addonSet.hasStreams {
            Button("Find", systemImage: "magnifyingglass") { router.pushLibrary(media) }
        }
    }

    /// The same words as the iPhone's rows.
    private static func explain(_ weakness: String) -> String {
        switch weakness {
        case "720p", "480p": "Below 1080p"
        case "AV1": "AV1: no hardware decoding on Apple TV"
        default: "\(weakness) source"
        }
    }
}
