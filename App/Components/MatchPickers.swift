import DoveAppCore
import DoveKit
import SwiftUI

// "Wrong title / book / album / game?": pick the right match. Shared by the iPhone and the Mac.

/// Search the metadata addon and pick the right title; the choice sticks for every release with the same guess.
struct MatchPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let title: LibraryTitle
    @State private var query = ""
    @State private var results: [MediaSummary] = []
    @State private var isSearching = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Title", text: $query)
                        .submitLabel(.search)
                        .onSubmit(search)
                } footer: {
                    if let message { Text(message) }
                }
                if isSearching {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                ForEach(results) { media in
                    Button {
                        choose(media)
                    } label: {
                        MediaRow(item: media)
                    }
                    .tint(.primary)
                }
            }
            .navigationTitle("Choose the title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear {
                query = title.guess.title
                search()
            }
        }
    }

    private func search() {
        guard model.addonSet.canSearch else {
            message = "Add a TMDB key or a Stremio addon that can search in Settings."
            return
        }
        isSearching = true
        Task {
            do {
                results = try await model.addonSet.search(query)
                message = results.isEmpty ? "Nothing found." : nil
            } catch {
                message = error.localizedDescription
            }
            isSearching = false
        }
    }

    private func choose(_ media: MediaSummary) {
        let keys = Set(title.items.map(\.guess.key))
        Task {
            await model.library.setMatch(media, for: keys)
            dismiss()
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

/// Search the music sources and pick the right album; the choice sticks for every release with the same
/// guessed artist and title.
struct AlbumPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let album: AlbumTitle
    @State private var query = ""
    @State private var results: [AlbumSummary] = []
    @State private var isSearching = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Artist and album", text: $query)
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
                        AlbumRow(album: result)
                    }
                    .tint(.primary)
                }
            }
            .navigationTitle("Choose the album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear {
                query = album.guess.query
                search()
            }
        }
    }

    private func search() {
        isSearching = true
        Task {
            do {
                results = try await model.musicMetadata.search(query)
                message = results.isEmpty ? "Nothing found." : nil
            } catch {
                message = error.localizedDescription
            }
            isSearching = false
        }
    }

    private func choose(_ result: AlbumSummary) {
        let keys = Set(album.items.compactMap(\.albumGuess?.key))
        Task {
            await model.library.setAlbumMatch(result, for: keys)
            dismiss()
        }
    }
}

/// Search the game sources and pick the right game; the choice sticks for every release with the same guess.
struct GamePickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: GameTitle
    @State private var query = ""
    @State private var results: [GameSummary] = []
    @State private var isSearching = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Game title", text: $query)
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
                        GameRow(game: result)
                    }
                    .tint(.primary)
                }
            }
            .navigationTitle("Choose the game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear {
                query = game.guess.query
                search()
            }
        }
    }

    private func search() {
        isSearching = true
        Task {
            do {
                results = try await model.gameMetadata.search(query)
                message = results.isEmpty ? "Nothing found." : nil
            } catch {
                message = error.localizedDescription
            }
            isSearching = false
        }
    }

    private func choose(_ result: GameSummary) {
        let keys = Set(game.items.compactMap(\.gameGuess?.key))
        Task {
            await model.library.setGameMatch(result, for: keys)
            dismiss()
        }
    }
}
