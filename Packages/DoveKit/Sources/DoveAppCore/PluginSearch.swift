import DoveKit
import Foundation
import Observation

/// Search rows from the plugins that serve a category, asked in parallel; each plugin's answer shows as it
/// arrives. A row's Download asks the plugin for the file (`AppModel.getFile`).
@MainActor @Observable
public final class PluginSearch {
    public init() {}

    public struct Answer: Identifiable {
        public let call: PluginCall
        public var results: [PluginResult] = []
        public var error: String?
        public var id: String { call.id }
    }

    public private(set) var answers: [Answer] = []
    public private(set) var isSearching = false
    public private(set) var busy: Set<String> = []
    public var message: String?
    /// What the rows were searched for: their default kind and the book or title picked before.
    public private(set) var category: SearchCategory = .books
    public private(set) var book: BookSummary?
    public private(set) var media: MediaSummary?
    @ObservationIgnored private var task: Task<Void, Never>?

    public var isEmpty: Bool { answers.allSatisfy { $0.results.isEmpty && $0.error == nil } }
    /// Plugins were asked (some serve the category), whatever they answered.
    public var wasAsked: Bool { !answers.isEmpty }
    public var resultCount: Int { answers.reduce(0) { $0 + $1.results.count } }

    public func clear() {
        task?.cancel()
        answers = []
        isSearching = false
        message = nil
    }

    public func search(
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

    public func get(_ row: PluginResult, from call: PluginCall, to place: FilePlace?, using model: AppModel) {
        let key = "\(call.id)/\(row.id)"
        busy.insert(key)
        Task {
            message = await model.getFile(
                from: call, id: row.id, title: row.title, kind: row.kind ?? category.contentKind, book: book, media: media, to: place
            )
            busy.remove(key)
        }
    }

    public func isBusy(_ row: PluginResult, of call: PluginCall) -> Bool { busy.contains("\(call.id)/\(row.id)") }
}
