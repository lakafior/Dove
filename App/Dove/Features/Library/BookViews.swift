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

