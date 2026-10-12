import DoveKit
import SwiftUI

/// The smart field: a magnet, info hash, .torrent/.nzb URL or hoster link opens the add sheet;
/// anything else searches titles through the user's Stremio addons, or, in Other, names through Dove's
/// own Newznab indexers in the picked category (software, music, books…). Movie and series searches never
/// see those results: indexers are asked for Movies/TV only there.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var pendingSource: Source?
    @State private var message: String?
    @State private var results: [MediaSummary] = []
    @State private var isSearching = false
    @State private var typeFilter: MediaType?
    @AppStorage("searchScope") private var scope: SearchScope = .media
    @AppStorage("otherCategory") private var category: NewznabCategory = .all
    @State private var otherResults: [StreamCandidate] = []
    @State private var busy: Set<StreamCandidate.ID> = []
    @Environment(\.scenePhase) private var scenePhase
    /// `UIPasteboard.changeCount` the banner was last answered for, so it does not come back for the same copy.
    @AppStorage("clipboardAnsweredChange") private var answeredChange = -1
    @State private var pasteboardChange = -1
    @State private var pasteboardHasContent = false

    private var visibleResults: [MediaSummary] {
        guard let typeFilter else { return results }
        return results.filter { $0.type == typeFilter }
    }

    var body: some View {
        NavigationStack {
            List {
                if pasteboardHasContent, pasteboardChange != answeredChange {
                    clipboardBanner
                }
                Section {
                    TextField(scope == .media ? "Title, magnet or link" : "Name, magnet or link", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit(handleSubmit)
                    if scope == .other {
                        Picker("Category", selection: $category) {
                            ForEach(NewznabCategory.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    }
                } header: {
                    Picker("Search", selection: $scope) {
                        ForEach(SearchScope.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .textCase(nil)
                    .padding(.bottom, 4)
                } footer: {
                    if let message { Text(message) }
                }

                if isSearching {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowBackground(Color.clear)
                }

                if scope == .other, !otherResults.isEmpty {
                    otherResultsSection
                }

                if scope == .media, !results.isEmpty {
                    Section {
                        ForEach(visibleResults) { item in
                            NavigationLink(value: item) { MediaRow(item: item) }
                        }
                    } header: {
                        Picker("Type", selection: $typeFilter) {
                            Text("All").tag(MediaType?.none)
                            Text("Movies").tag(MediaType?.some(.movie))
                            Text("Series").tag(MediaType?.some(.series))
                        }
                        .pickerStyle(.segmented)
                        .textCase(nil)
                        .padding(.bottom, 4)
                    }
                }
            }
            .navigationTitle("Dove")
            .navigationDestination(for: MediaSummary.self) { MediaDetailView(item: $0) }
            .onChange(of: scope) { message = nil }
            .onChange(of: category) { otherResults = [] }
            .onAppear(perform: checkPasteboard)
            .onChange(of: scenePhase) { if scenePhase == .active { checkPasteboard() } }
            .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in checkPasteboard() }
            .sheet(item: $pendingSource) { source in
                AddSourceSheet(source: source) { result in
                    pendingSource = nil
                    message = result
                    if result.hasPrefix("Added") { text = "" }
                }
            }
        }
    }

    /// Offers what was copied in another app. Only `hasStrings`/`hasURLs` are read here, which iOS does not report
    /// as pasting; the content itself comes through `PasteButton`, i.e. only when the user taps it.
    private var clipboardBanner: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
                Text("Add what you copied?").font(.subheadline)
                Spacer()
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in usePasted(strings.first ?? "") }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.capsule)
                Button {
                    answeredChange = pasteboardChange
                } label: {
                    Image(systemName: "xmark").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
        }
    }

    private func checkPasteboard() {
        let pasteboard = UIPasteboard.general
        pasteboardChange = pasteboard.changeCount
        pasteboardHasContent = pasteboard.hasURLs || pasteboard.hasStrings
    }

    /// A magnet or link (also inside longer text) opens the add sheet; anything else becomes a title search.
    private func usePasted(_ pasted: String) {
        answeredChange = pasteboardChange
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let source = SourceDetector.firstSource(in: trimmed) {
            results = []
            pendingSource = source
        } else {
            text = trimmed
            handleSubmit()
        }
    }

    private func handleSubmit() {
        message = nil
        if let source = SourceDetector.firstSource(in: text) {
            results = []
            pendingSource = source
            return
        }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        if scope == .other { return searchOther(query) }
        guard model.addonSet.canSearch else {
            message = "Add a Stremio addon that can search (for example AIOMetadata or Cinemeta) in Settings."
            return
        }
        isSearching = true
        Task {
            do {
                results = try await model.addonSet.search(query)
                if results.isEmpty { message = "Nothing found." }
            } catch {
                message = error.localizedDescription
            }
            isSearching = false
        }
    }
}

// MARK: - Other

extension SearchView {
    @ViewBuilder
    var otherResultsSection: some View {
        @Bindable var model = model
        Section {
            Toggle("Download only", isOn: $model.downloadOnly)
            ForEach(otherResults) { candidate in
                OtherResultRow(
                    candidate: candidate,
                    isBusy: busy.contains(candidate.id),
                    downloadOnly: model.downloadOnly,
                    onAdd: canAdd(candidate) ? { addOther(candidate) } : nil
                )
            }
        } footer: {
            if otherResults.contains(where: { !canAdd($0) }) {
                Text("NZBs need nzbdav or TorBox Usenet, torrents a debrid service: set them up in Settings.")
            }
        }
    }

    /// Words in the picked category, through Dove's own indexers. Same release from several indexers: one row.
    func searchOther(_ query: String) {
        guard !model.newznab.isEmpty else {
            message = "Add a Newznab or Torznab indexer in Settings › Search › Indexers to search beyond movies and series."
            return
        }
        isSearching = true
        otherResults = []
        let search = model.newznab
        let category = category
        Task {
            let found = await search.search(.text(query, category: category))
            var seen = Set<String>()
            otherResults = found.candidates.filter { seen.insert($0.title.lowercased()).inserted }
            let failures = found.failures.joined(separator: "\n")
            message = otherResults.isEmpty
                ? (failures.isEmpty ? "Nothing found." : failures)
                : (failures.isEmpty ? nil : failures)
            isSearching = false
        }
    }

    func canAdd(_ candidate: StreamCandidate) -> Bool {
        candidate.kind == .usenet ? model.usenetBackend != nil : !model.backends(usenet: false).isEmpty
    }

    /// Adds through the priority order (NZBs: nzbdav, then TorBox Usenet; torrents: the debrid order);
    /// "Download only" fetches every file.
    func addOther(_ candidate: StreamCandidate) {
        guard let source = candidate.librarySource else { return }
        busy.insert(candidate.id)
        Task {
            defer { busy.remove(candidate.id) }
            do {
                // A Torznab result's .torrent link carries the indexer's key: fetch it here, never hand it over.
                let result = try await model.router.add(try await IndexerTorrent.prepare(source))
                message = model.downloadOnly
                    ? await model.startDownloadOnly(result.itemID, on: result.backend, name: candidate.title, pick: .allVideos)
                    : "Added to \(result.backend.displayName)."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

struct MediaRow: View {
    let item: MediaSummary

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(url: item.poster)
                .frame(width: 46, height: 69)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.headline).lineLimit(2)
                HStack(spacing: 6) {
                    Text(item.type == .movie ? "Movie" : "Series")
                    if let year = item.releaseInfo { Text(year) }
                    if let rating = item.imdbRating { Text("★ \(rating)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct PosterImage: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(.quaternary)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// The app's add sheet: the shared add screen with the app's configured services and priority.
struct AddSourceSheet: View {
    @Environment(AppModel.self) private var model
    let source: Source
    let onFinish: (String) -> Void

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            AddSourceView(
                source: source,
                router: model.router,
                onClose: { onFinish($0 ?? "") },
                downloadOnly: $model.downloadOnly,
                startDownloadOnly: { backend, itemID in
                    await model.startDownloadOnly(itemID, on: backend, name: source.displayName, pick: .allVideos)
                }
            )
        }
        .presentationDetents([.medium, .large])
    }
}
