import AppKit
import DoveAppCore
import DoveKit
import SwiftUI

/// A book page's own buttons, the Mac form of the iPhone's Read section and audiobook buttons. An ebook opens in the
/// Mac's reader for its format (Books for EPUB and PDF), goes by mail to a reader's address (Kindle, PocketBook, any
/// e-mail set in Settings › Reading), shows in the Finder, or goes to Calibre. An audiobook plays in Dove's player
/// (the bar at the bottom), continues where it was left, or starts over.
struct MacBookActions: View {
    @Environment(AppModel.self) private var model
    let book: BookTitle

    @State private var isWorking = false
    @State private var message: String?
    /// Books Calibre said are this one: shown before adding a second copy.
    @State private var calibreDuplicates: [String]?

    private static let cache = BookFileCache()

    var body: some View {
        Group {
            if book.format == .audiobook { audiobookButtons } else { ebookButtons }
            if isWorking { ProgressView().controlSize(.small) }
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        }
        .confirmationDialog("Calibre may already have this book", isPresented: Binding(
            get: { calibreDuplicates != nil }, set: { if !$0 { calibreDuplicates = nil } }
        ), titleVisibility: .visible) {
            Button("Add Anyway") { addToCalibre(allowDuplicate: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(calibreDuplicates?.joined(separator: "\n") ?? "")
        }
    }

    // MARK: Audiobooks

    @ViewBuilder
    private var audiobookButtons: some View {
        let saved = model.audiobook.savedPosition(for: book.guess.key)
        Button(saved == nil ? "Play" : "Continue", systemImage: "play.fill") { play() }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)
        if saved != nil {
            Button("Start Over", systemImage: "backward.end") {
                model.audiobook.clearPosition(for: book.guess.key)
                play()
            }
            .buttonStyle(.bordered)
        }
    }

    private func play() {
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            message = await model.playAudiobook(book)
        }
    }

    // MARK: Ebooks

    @ViewBuilder
    private var ebookButtons: some View {
        Button("Read", systemImage: "book") { open(reveal: false) }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)
            .help("Opens the best file of the ready releases in its reader (EPUB and PDF in Books)")
        Menu("Send", systemImage: "paperplane") {
            ForEach(model.readingTargets.filter(\.isMail)) { target in
                Button(target.actionTitle, systemImage: "paperplane") { send(to: target) }
            }
            Button("Show in Finder", systemImage: "folder") { open(reveal: true) }
            if !book.backends.contains(.calibre), model.backend(.calibre) is CalibreBackend {
                Divider()
                Button("Add to Calibre", systemImage: "books.vertical") { addToCalibre(allowDuplicate: false) }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
        .disabled(isWorking)
    }

    /// Opens the file in its reader, or selects it in the Finder.
    private func open(reveal: Bool) {
        run { items in
            guard let pick = BookFiles.pickAny(from: items) else { return BookFiles.Refusal.noBookFile.message(for: .appleBooks) }
            let url = try await localFile(for: pick)
            if reveal {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }

    /// A Mail draft to the reader's address with the file attached (the system's compose service, any mail app).
    private func send(to target: ReadingTarget) {
        run { items in
            let pick: BookFiles.Pick
            switch BookFiles.pick(from: items, for: target) {
            case .success(let found): pick = found
            case .failure(let refusal): return refusal.message(for: target)
            }
            let url = try await localFile(for: pick)
            guard let service = NSSharingService(named: .composeEmail) else { return "No mail app is set up on this Mac." }
            service.recipients = [model.mailAddress(for: target)]
            service.subject = book.name
            service.perform(withItems: [url])
            return nil
        }
    }

    /// The best ebook of a service's ready release goes to Calibre with this page's title, authors and description.
    private func addToCalibre(allowDuplicate: Bool) {
        run { items in
            let fromServices = items.filter { $0.backend != .calibre }
            guard let pick = BookFiles.pickAny(from: fromServices) else {
                return fromServices.isEmpty ? "No release is ready on a service yet." : BookFiles.Refusal.noBookFile.message(for: .appleBooks)
            }
            let url = try await localFile(for: pick)
            let summary = book.book ?? BookSummary(id: book.id, title: book.name, authors: book.author.map { [$0] } ?? [])
            let fileName = AppModel.calibreFileName(book: summary, fileName: pick.file.name)
            switch try await model.addToCalibre(file: url, fileName: fileName, book: book.book, allowDuplicate: allowDuplicate) {
            case .duplicates(let books):
                calibreDuplicates = books
                return nil
            case let outcome:
                return outcome.message
            }
        }
    }

    // MARK: Files

    /// Runs one action over the ready releases; its answer (or error) shows under the buttons.
    private func run(_ action: @escaping ([LibraryItem]) async throws -> String?) {
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do {
                let items = try await readyItems()
                message = items.isEmpty ? "No release is ready yet." : try await action(items)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Ready releases in the book's order; services that list items without files are asked for them.
    private func readyItems() async throws -> [LibraryItem] {
        var items: [LibraryItem] = []
        for item in book.items.map(\.item) where item.status == .ready {
            if item.files.isEmpty, let backend = model.backend(item.backend) {
                items.append(try await backend.item(item.id))
            } else {
                items.append(item)
            }
        }
        return items
    }

    /// The copy in Downloads when the user already has it, iCloud Drive's own file, else the Read cache.
    private func localFile(for pick: BookFiles.Pick) async throws -> URL {
        if let record = model.downloads.records.first(where: {
            $0.state == .finished && $0.isSameFile(backend: pick.item.backend, itemID: pick.item.id, fileID: pick.file.id)
        }), let url = model.downloads.fileURL(for: record) {
            return url
        }
        guard let backend = model.backend(pick.item.backend) else {
            throw BackendError.api(message: "\(pick.item.backend.displayName) is no longer configured.")
        }
        if pick.item.backend.isOnDevice, let url = try await backend.downloadRequest(itemID: pick.item.id, fileID: pick.file.id).url {
            return url
        }
        return try await Self.cache.fetch(pick) {
            try await backend.downloadRequest(itemID: pick.item.id, fileID: pick.file.id)
        }
    }
}
