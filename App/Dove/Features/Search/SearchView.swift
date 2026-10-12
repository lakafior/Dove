import DoveKit
import SwiftUI

/// The smart field: a magnet, info hash, .torrent/.nzb URL or hoster link opens the add sheet;
/// anything else searches titles through the user's Stremio addons.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var pendingSource: Source?
    @State private var message: String?
    @State private var results: [MediaSummary] = []
    @State private var isSearching = false
    @State private var typeFilter: MediaType?
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
                    TextField("Title, magnet or link", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit(handleSubmit)
                } footer: {
                    if let message { Text(message) }
                }

                if isSearching {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowBackground(Color.clear)
                }

                if !results.isEmpty {
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
        NavigationStack {
            AddSourceView(source: source, router: model.router) { message in
                onFinish(message ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }
}
