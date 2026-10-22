import DoveAppCore
import DoveKit
import SwiftUI

/// The large search field, Spotlight style: the words, the category as a menu inside the field, suggestions under it
/// while typing (↑↓ pick one, Return opens it; without a pick Return searches). On top of the Search page, and in the
/// floating panel ⌘F opens on any page.
struct SpotlightField: View {
    @Binding var text: String
    @Binding var category: SearchCategory
    let categories: [SearchCategory]
    var focus: FocusState<Bool>.Binding
    var suggestions: [SpotlightSuggestion] = []
    var onPick: (SpotlightSuggestion) -> Void = { _ in }
    let onSubmit: () -> Void

    /// The suggestion ↑↓ moved to; nil means Return searches the words.
    @State private var highlighted: SpotlightSuggestion.ID?

    var body: some View {
        VStack(spacing: 0) {
            field
            if !suggestions.isEmpty {
                Divider().padding(.horizontal, 12)
                VStack(spacing: 2) {
                    ForEach(suggestions) { suggestion in
                        SuggestionRow(suggestion: suggestion, isHighlighted: suggestion.id == highlighted)
                            .onTapGesture { onPick(suggestion) }
                            .onHover { inside in if inside { highlighted = suggestion.id } }
                    }
                }
                .padding(8)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .animation(.easeOut(duration: 0.12), value: suggestions)
        .onChange(of: suggestions) { highlighted = nil }
    }

    private var field: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .scaledFont(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .scaledFont(.title2)
                .focused(focus)
                .onSubmit {
                    if let highlighted, let pick = suggestions.first(where: { $0.id == highlighted }) {
                        onPick(pick)
                    } else {
                        onSubmit()
                    }
                }
                .onKeyPress(.downArrow) { move(by: 1) }
                .onKeyPress(.upArrow) { move(by: -1) }
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Menu {
                Picker("Category", selection: $category) {
                    ForEach(categories, id: \.self) { item in
                        Label(item.displayName, systemImage: item.symbolName).tag(item)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(category.displayName, systemImage: category.symbolName)
                    .labelStyle(.titleAndIcon)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.large)
            .fixedSize()
            .help("What to search (⌘1…⌘7)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func move(by step: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        let index = suggestions.firstIndex { $0.id == highlighted }
        let next = index.map { $0 + step } ?? (step > 0 ? 0 : suggestions.count - 1)
        highlighted = suggestions.indices.contains(next) ? suggestions[next].id : nil
        return .handled
    }

    private var prompt: String {
        switch category {
        case .media: "Movies and series, or a link"
        case .books: "Books by title or author"
        case .audiobooks: "Audiobooks by title or author"
        case .music: "Albums or artists"
        case .games: "Games"
        default: "Search your indexers"
        }
    }
}

/// A suggestion: poster (or symbol), title, what it is.
private struct SuggestionRow: View {
    let suggestion: SpotlightSuggestion
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = suggestion.image {
                    PosterImage(url: image).aspectRatio(suggestion.ratio, contentMode: .fit)
                } else {
                    Image(systemName: suggestion.symbol)
                        .scaledFont(.title3)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 28, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title).scaledFont(.body, weight: .medium).lineLimit(1)
                if let subtitle = suggestion.subtitle {
                    Text(subtitle).scaledFont(.caption).foregroundStyle(isHighlighted ? .primary : .secondary)
                }
            }
            Spacer()
            if isHighlighted { Image(systemName: "return").foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHighlighted ? Color.accentColor.opacity(0.35) : .clear, in: .rect(cornerRadius: 10))
        .contentShape(.rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
