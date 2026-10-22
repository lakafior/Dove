import DoveAppCore
import DoveKit
import SwiftUI

struct BookRoute: Hashable {
    let id: String
}

/// One book across services: cover, author, description, then its releases.
struct BookTitleView: View {
    @Environment(AppModel.self) private var model
    let bookID: String
    @State private var isFixingMatch = false
    @State private var showsFullDescription = false

    private var book: BookTitle? { model.library.book(id: bookID) }

    var body: some View {
        List {
            if let book {
                Section {
                    header(book)
                    if let description = book.book?.description {
                        Text(description)
                            .font(.footnote)
                            .lineLimit(showsFullDescription ? nil : 6)
                            .onTapGesture { showsFullDescription.toggle() }
                    }
                    if let link = book.book?.link {
                        Link(destination: link) {
                            Label(book.book?.sourceName(plugins: model.plugins.manifests()) ?? "Open", systemImage: "safari")
                        }
                        .font(.footnote)
                    }
                    Button("Wrong book?", systemImage: "arrow.triangle.2.circlepath") { isFixingMatch = true }
                        .font(.footnote)
                }
                if book.format == .ebook {
                    BookReadSection(book: book)
                } else {
                    AudiobookPlaySection(book: book)
                }
                Section("Releases") {
                    ForEach(book.items) { item in
                        NavigationLink(value: item) { ShelfItemRow(item: item) }
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    Task { await model.library.delete(item, using: model) }
                                }
                            }
                    }
                }
            } else {
                ContentUnavailableView("Not in your library anymore", systemImage: "tray")
            }
        }
        .navigationTitle(book?.name ?? "")
        .userActivity(SpotlightIndex.viewActivity, isActive: book != nil) { activity in
            SpotlightIndex.describe(activity, id: "book:\(bookID)", title: book?.name ?? "")
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isFixingMatch) {
            if let book { BookPickerSheet(book: book) }
        }
    }

    private func header(_ book: BookTitle) -> some View {
        HStack(alignment: .top, spacing: 12) {
            BookCover(book: book)
                .frame(width: book.format == .audiobook ? 120 : 96)
            VStack(alignment: .leading, spacing: 6) {
                Text(book.name).font(.title3.bold())
                if let author = book.author { Text(author).font(.subheadline) }
                HStack(spacing: 6) {
                    Text(book.format.displayName)
                    if let year = book.year { Text(year) }
                    if book.size > 0 { Text(book.size.formatted(.byteCount(style: .file))) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(book.backends, id: \.self) { BackendBadge(backend: $0) }
                }
                if book.book == nil {
                    Text("No cover found yet. Open Library and Apple Books are searched on refresh.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Search Open Library and Apple Books and pick the right book; the choice sticks for every release with the
/// same guessed author and title.
struct BookPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let book: BookTitle
    @State private var query = ""
    @State private var results: [BookSummary] = []
    @State private var isSearching = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Author and title", text: $query)
                        .submitLabel(.search)
                        .onSubmit(search)
                } footer: {
                    if let message { Text(message) }
                }
                if isSearching {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                ForEach(results) { result in
                    Button {
                        choose(result)
                    } label: {
                        BookRow(book: result, format: book.format)
                    }
                    .tint(.primary)
                }
            }
            .navigationTitle("Choose the book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear {
                query = book.guess.query
                search()
            }
        }
    }

    private func search() {
        isSearching = true
        Task {
            do {
                results = try await model.library.searchBooks(query, format: book.format)
                message = results.isEmpty ? "Nothing found." : nil
            } catch {
                message = error.localizedDescription
            }
            isSearching = false
        }
    }

    private func choose(_ result: BookSummary) {
        let keys = Set(book.items.compactMap(\.bookGuess?.key))
        Task {
            await model.library.setBookMatch(result, for: keys)
            dismiss()
        }
    }
}

struct BookRow: View {
    @Environment(AppModel.self) private var model
    let book: BookSummary
    let format: BookFormat
    /// The library's copy of this book (`HeldBooks`), marked so it is not fetched twice.
    var held: BookTitle?

    var body: some View {
        HStack(spacing: 12) {
            CachedImage(url: book.cover) {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 46, height: format == .audiobook ? 46 : 69)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).font(.headline).lineLimit(2)
                HStack(spacing: 6) {
                    if let author = book.authors.first { Text(author) }
                    if let year = book.year { Text(String(year)) }
                    Text(book.sourceName(plugins: model.plugins.manifests()))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let held { HeldBookMark(title: held) }
            }
        }
    }
}

/// "In Calibre" (or "In library" for a copy on a service) under a search result the library already holds.
struct HeldBookMark: View {
    let title: BookTitle

    var body: some View {
        Label(title.heldLabel, systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(title.backends.contains(.calibre) ? BackendID.calibre.tint : .green)
    }
}

extension BookTitle {
    /// Where the library keeps it, Calibre first: it is the user's own copy.
    var heldLabel: String {
        backends.contains(.calibre) ? "In Calibre" : "In library"
    }

    /// The formats the library's copies come in ("EPUB, MOBI"), from file names.
    var heldFormats: String {
        let formats = items.flatMap(\.item.files).map { BookFiles.format(of: $0.name).uppercased() }
            .filter { BookFiles.ebookFormats.contains($0.lowercased()) || AudiobookTracks.playableExtensions.contains($0.lowercased()) }
        return formats.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ")
    }
}

