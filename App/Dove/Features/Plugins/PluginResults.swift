import DoveAppCore
import DoveKit
import SwiftUI

/// Which results a screen with plugins shows: its own (addons, indexers) or the plugins'.
enum ResultsTab: Hashable {
    case sources
    case plugins
}

/// Two segments for a screen whose own results can run long (a popular title's sources), so the plugins'
/// rows are one tap away instead of below all of them.
struct ResultsTabPicker: View {
    @Binding var tab: ResultsTab
    let sourcesTitle: String
    let sourcesCount: Int?
    let plugins: PluginSearch

    var body: some View {
        Picker("Results", selection: $tab) {
            Text(label(sourcesTitle, sourcesCount)).tag(ResultsTab.sources)
            Text(label("Plugins", plugins.isSearching && plugins.resultCount == 0 ? nil : plugins.resultCount)).tag(ResultsTab.plugins)
        }
        .pickerStyle(.segmented)
    }

    private func label(_ title: String, _ count: Int?) -> String { count.map { "\(title) (\($0))" } ?? title }
}

extension View {
    /// The picker pinned above a list, shown only when plugins were asked.
    func resultsTabs(_ tab: Binding<ResultsTab>, sources: String, count: Int?, plugins: PluginSearch) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if plugins.wasAsked {
                ResultsTabPicker(tab: tab, sourcesTitle: sources, sourcesCount: count, plugins: plugins)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
    }
}

/// One section per plugin with its rows, inside a `List`.
struct PluginResultsSections: View {
    @Environment(AppModel.self) private var model
    let search: PluginSearch
    /// On a plugins-only tab: a spinner while nothing has come back, and a line when nothing was found.
    var showsState = false

    var body: some View {
        if showsState, search.resultCount == 0 {
            if search.isSearching {
                HStack { Spacer(); ProgressView("Asking your plugins…"); Spacer() }
                    .listRowBackground(Color.clear)
            } else if search.isEmpty {
                ContentUnavailableView("No results from your plugins", systemImage: "puzzlepiece")
            }
        }
        if let message = search.message {
            Section { Text(message).font(.footnote).foregroundStyle(.secondary).onTapGesture { search.message = nil } }
        }
        ForEach(search.answers) { answer in
            if !answer.results.isEmpty || answer.error != nil {
                Section {
                    if let error = answer.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    ForEach(answer.results) { row in
                        PluginResultRow(row: row, kind: row.kind ?? search.category.contentKind, isBusy: search.isBusy(row, of: answer.call)) { place in
                            search.get(row, from: answer.call, to: place, using: model)
                        }
                    }
                } header: {
                    Label(answer.call.manifest.name, systemImage: "puzzlepiece")
                }
            }
        }
    }
}

private struct PluginResultRow: View {
    @Environment(AppModel.self) private var model
    let row: PluginResult
    let kind: ContentKind
    let isBusy: Bool
    let get: (FilePlace?) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let cover = row.cover {
                CachedImage(url: cover) { Rectangle().fill(.quaternary) }
                    .frame(width: 40, height: kind == .audiobooks ? 40 : 60)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: kind.symbol).foregroundStyle(.secondary).frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.subheadline).lineLimit(3)
                HStack(spacing: 6) {
                    if let author = row.author { Text(author) }
                    if let year = row.year { Text(String(year)) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if let format = row.format {
                        Text(format.uppercased())
                            .padding(.horizontal, 5)
                            .background(.quaternary, in: Capsule())
                    }
                    if let size = row.size { Text(size.formatted(.byteCount(style: .file))).monospacedDigit() }
                    if let language = row.language { Text(language) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // A tap goes to the kind's default place; a long press picks another.
            Menu {
                ForEach(model.places(for: kind), id: \.self) { place in
                    Button(model.placeName(of: place), systemImage: place.symbol) { get(place) }
                }
            } label: {
                Group {
                    if isBusy { ProgressView() } else { Image(systemName: model.place(for: kind).symbol) }
                }
                .frame(width: 22, height: 22)
            } primaryAction: {
                get(nil)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy)
            .accessibilityLabel("Download")
        }
        .padding(.vertical, 2)
    }
}
