import DoveKit
import SwiftUI

struct BookRoute: Hashable {
    let id: String
}

/// Cover tile for a book (2:3) or an audiobook (square): artwork, or a generated cover with the title and
/// author; name, author, services, and a status mark.
struct BookCard: View {
    let book: BookTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                BookCover(book: book)
                LibraryStatusMark(status: book.status, count: book.items.count).padding(5)
            }
            Text(book.name).font(.caption.weight(.medium)).lineLimit(1)
            HStack(spacing: 3) {
                if let author = book.author { Text(author).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 2)
                ForEach(book.backends, id: \.self) { BackendBadge(backend: $0) }
            }
        }
    }
}

/// The artwork in the book's shape; until it loads, or when there is none, a cover made from the title.
struct BookCover: View {
    let book: BookTitle

    var body: some View {
        CachedImage(url: book.book?.cover) {
            GeneratedCover(title: book.name, author: book.author, format: book.format)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .aspectRatio(book.format.coverRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: book.format == .audiobook ? 10 : 4))
        .overlay(alignment: .bottomLeading) {
            if book.format == .audiobook {
                Image(systemName: "headphones")
                    .font(.caption2.bold())
                    .padding(5)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(5)
            }
        }
    }
}

/// A plain cover in a colour picked from the title, so a shelf without artwork still looks like a shelf.
private struct GeneratedCover: View {
    let title: String
    let author: String?
    let format: BookFormat

    private var hue: Double {
        Double(title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color(hue: hue, saturation: 0.45, brightness: 0.55), Color(hue: hue, saturation: 0.55, brightness: 0.3)],
                startPoint: .top,
                endPoint: .bottom
            )
            if format == .ebook {
                // A spine.
                Rectangle().fill(.black.opacity(0.18)).frame(width: 5)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.footnote, design: .serif).weight(.semibold))
                    .lineLimit(4)
                if let author {
                    Text(author).font(.system(.caption2, design: .serif)).opacity(0.8).lineLimit(2)
                }
            }
            .foregroundStyle(.white)
            .padding(.leading, format == .ebook ? 12 : 8)
            .padding([.top, .trailing], 8)
        }
    }
}

extension BookFormat {
    /// Book covers are portrait, audiobook artwork is square.
    var coverRatio: CGFloat { self == .audiobook ? 1 : 2 / 3 }

    var displayName: String { self == .audiobook ? "Audiobook" : "Book" }
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
                            Label(link.host()?.contains("apple") == true ? "Apple Books" : "Open Library", systemImage: "safari")
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

private struct BookRow: View {
    let book: BookSummary
    let format: BookFormat

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
                    Text(book.id.hasPrefix("itunes:") ? "Apple Books" : "Open Library")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

