import DoveKit
import SwiftUI

/// A book picked from the metadata search, in the category it was searched in.
struct BookSearchRoute: Hashable {
    let book: BookSummary
    let category: SearchCategory
}

/// One book from Open Library or Apple Books: cover and description, then the indexers' releases of it
/// (`t=book` with title and author where an indexer has it, else "author title"), this book's first.
struct BookReleasesView: View {
    @Environment(AppModel.self) private var model
    let route: BookSearchRoute
    @State private var releases: ReleaseList
    @State private var expanded = false

    init(route: BookSearchRoute) {
        self.route = route
        _releases = State(initialValue: ReleaseList(book: route.book, format: route.category.bookFormat ?? .ebook))
    }

    private var format: BookFormat { route.category.bookFormat ?? .ebook }

    var body: some View {
        List {
            Section { header }
            if releases.isSearching {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowBackground(Color.clear)
            }
            if let message = releases.message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            if !releases.isEmpty {
                ReleaseListSection(list: releases, title: "Releases")
            }
        }
        .navigationTitle(route.book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SourcesMenu(category: route.category, refresh: releases.isSearching) }
        }
        .task { if releases.isEmpty, releases.message == nil { search() } }
        .onChange(of: model.sourceSelection) { search() }
        .refreshable { search() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            CachedImage(url: route.book.cover) {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 90, height: format == .audiobook ? 90 : 135)
            .clipShape(RoundedRectangle(cornerRadius: format == .audiobook ? 8 : 4))
            VStack(alignment: .leading, spacing: 6) {
                Text(route.book.title).font(.headline)
                if !route.book.authors.isEmpty {
                    Text(route.book.authors.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if let year = route.book.year { Text(String(year)) }
                    Text(format.displayName)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let description = route.book.description {
                    Text(description)
                        .font(.footnote)
                        .lineLimit(expanded ? nil : 4)
                        .onTapGesture { expanded.toggle() }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func search() {
        guard let category = route.category.newznabCategory else { return }
        let query = NewznabQuery.book(title: route.book.searchTitle, author: route.book.authors.first, category: category)
        releases.search(query, in: route.category, model: model)
    }
}
