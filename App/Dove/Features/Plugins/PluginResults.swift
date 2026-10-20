import DoveKit
import SwiftUI

/// Search rows from the plugins that serve a category, asked in parallel; each plugin's answer shows as it
/// arrives. A row's Download asks the plugin for the file (`AppModel.getFile`).
@MainActor @Observable
final class PluginSearch {
    struct Answer: Identifiable {
        let call: PluginCall
        var results: [PluginResult] = []
        var error: String?
        var id: String { call.id }
    }

    private(set) var answers: [Answer] = []
    private(set) var isSearching = false
    private(set) var busy: Set<String> = []
    var message: String?
    /// What the rows were searched for: their default kind and the book or title picked before.
    private(set) var category: SearchCategory = .books
    private(set) var book: BookSummary?
    private(set) var media: MediaSummary?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isEmpty: Bool { answers.allSatisfy { $0.results.isEmpty && $0.error == nil } }
    /// Plugins were asked (some serve the category), whatever they answered.
    var wasAsked: Bool { !answers.isEmpty }
    var resultCount: Int { answers.reduce(0) { $0 + $1.results.count } }

    func clear() {
        task?.cancel()
        answers = []
        isSearching = false
        message = nil
    }

    func search(
        _ query: String, category: SearchCategory, book: BookSummary? = nil, title: PluginTitle? = nil, media: MediaSummary? = nil,
        album: AlbumSummary? = nil, calls: [PluginCall]
    ) {
        clear()
        guard !calls.isEmpty, !query.isEmpty else { return }
        self.category = category
        self.book = book
        self.media = media
        answers = calls.map { Answer(call: $0) }
        isSearching = true
        task = Task {
            await withTaskGroup(of: (String, Result<[PluginResult], any Error>).self) { group in
                for call in calls {
                    group.addTask {
                        do {
                            let rows = try await PluginRunner().search(
                                call.manifest, script: call.script, settings: call.settings, query: query, category: category, book: book, title: title, album: album
                            )
                            return (call.id, .success(rows))
                        } catch {
                            return (call.id, .failure(error))
                        }
                    }
                }
                for await (id, result) in group {
                    guard !Task.isCancelled, let index = answers.firstIndex(where: { $0.id == id }) else { continue }
                    switch result {
                    case .success(let rows): answers[index].results = rows
                    case .failure(let error): answers[index].error = error.localizedDescription
                    }
                }
            }
            if !Task.isCancelled { isSearching = false }
        }
    }

    func get(_ row: PluginResult, from call: PluginCall, to place: FilePlace?, using model: AppModel) {
        let key = "\(call.id)/\(row.id)"
        busy.insert(key)
        Task {
            message = await model.getFile(
                from: call, id: row.id, title: row.title, kind: row.kind ?? category.contentKind, book: book, media: media, to: place
            )
            busy.remove(key)
        }
    }

    func isBusy(_ row: PluginResult, of call: PluginCall) -> Bool { busy.contains("\(call.id)/\(row.id)") }
}

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
                    Button(place.displayName, systemImage: place.symbol) { get(place) }
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
