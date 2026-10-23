import AppKit
import SwiftUI

/// The top of every Library page (title, series, book, album, artist, game), one layout for all: the backdrop (else
/// the cover, blurred) behind the artwork, the name, facts, badges, one row of buttons (Play first) and the
/// description with More. Text sits on a darkened band, so it stays readable on a bright backdrop.
struct MacPageHeader<Artwork: View, Badges: View, Buttons: View, Notes: View>: View {
    let title: String
    var subtitle: String?
    var facts: String?
    var description: String?
    /// The wide image behind the header; without one, the cover blurred.
    var backdrop: URL?
    var cover: URL?
    var artworkWidth: CGFloat = 170
    @ViewBuilder var artwork: Artwork
    @ViewBuilder var badges: Badges
    @ViewBuilder var buttons: Buttons
    /// Lines under the description: loading, messages, suggestions.
    @ViewBuilder var notes: Notes

    @State private var showsFullDescription = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 22) {
                artwork
                    .frame(width: artworkWidth)
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.largeTitle.bold()).lineLimit(2).textSelection(.enabled)
                    if let subtitle { Text(subtitle).font(.title3).foregroundStyle(.secondary) }
                    if let facts { Text(facts).foregroundStyle(.secondary) }
                    HStack(spacing: 6) { badges }
                    HStack(spacing: 8) { buttons }
                        .controlSize(.large)
                        .padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
            if let description, !description.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(description)
                        .lineLimit(showsFullDescription ? nil : 3)
                        .textSelection(.enabled)
                    Button(showsFullDescription ? "Less" : "More") {
                        withAnimation(.snappy) { showsFullDescription.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
                .frame(maxWidth: 760, alignment: .leading)
            }
            notes
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { MacBackdrop(url: backdrop, fallback: cover) }
        .clipped()
    }
}

/// A page header's background: the backdrop, else the cover blurred, darkened on the left where the text is and
/// faded into the window at the bottom.
struct MacBackdrop: View {
    let url: URL?
    let fallback: URL?

    var body: some View {
        ZStack {
            if let url {
                CachedImage(url: url) { Rectangle().fill(.quaternary) }
            } else if let fallback {
                CachedImage(url: fallback) { Rectangle().fill(.quaternary) }
                    .blur(radius: 40)
                    .scaleEffect(1.3)
                    .opacity(0.6)
            }
            LinearGradient(colors: [.black.opacity(0.65), .black.opacity(0.15)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor)], startPoint: .center, endPoint: .bottom)
        }
        .clipped()
    }
}
