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
    /// What the rows were searched for: their default kind and book.
    private(set) var category: SearchCategory = .books
    private(set) var book: BookSummary?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isEmpty: Bool { answers.allSatisfy { $0.results.isEmpty && $0.error == nil } }

    func clear() {
        task?.cancel()
        answers = []
        isSearching = false
        message = nil
    }

    func search(_ query: String, category: SearchCategory, book: BookSummary? = nil, calls: [PluginCall]) {
        clear()
        guard !calls.isEmpty, !query.isEmpty else { return }
        self.category = category
        self.book = book
        answers = calls.map { Answer(call: $0) }
        isSearching = true
        task = Task {
            await withTaskGroup(of: (String, Result<[PluginResult], any Error>).self) { group in
                for call in calls {
                    group.addTask {
                        do {
                            let rows = try await PluginRunner().search(
                                call.manifest, script: call.script, settings: call.settings, query: query, category: category, book: book
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
                from: call, id: row.id, title: row.title, kind: row.kind ?? category.contentKind, book: book, to: place
            )
            busy.remove(key)
        }
    }

    func isBusy(_ row: PluginResult, of call: PluginCall) -> Bool { busy.contains("\(call.id)/\(row.id)") }
}

/// One section per plugin with its rows, inside a `List`.
struct PluginResultsSections: View {
    @Environment(AppModel.self) private var model
    let search: PluginSearch

    var body: some View {
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
                ForEach(model.places, id: \.self) { place in
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
