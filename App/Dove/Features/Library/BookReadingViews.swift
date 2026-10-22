import DoveAppCore
import DoveKit
import MessageUI
import SwiftUI
import UIKit

/// "Read" on a book screen: the best file of the book's ready releases (`BookFiles`) goes to Apple Books (through the
/// share sheet: Books has no URL scheme for files) or by mail (a Mail draft to the Kindle, PocketBook or other
/// address set in Settings › Reading).
/// The file is downloaded to Caches once (`BookFileCache`), or taken from Downloads when it is already there.
struct BookReadSection: View {
    @Environment(AppModel.self) private var model
    let book: BookTitle
    @State private var working: Action?
    @State private var message: String?
    @State private var isAsking = false
    /// Books Calibre said are this one, when adding to Calibre: shown before adding a second copy.
    @State private var calibreDuplicates: [String]?

    enum Action: Hashable {
        case read(ReadingTarget)
        case share
        case calibre
    }

    /// Calibre is set up and does not hold this book yet.
    private var calibre: CalibreBackend? {
        guard !book.backends.contains(.calibre) else { return nil }
        return model.backend(.calibre) as? CalibreBackend
    }

    private static let cache = BookFileCache()

    /// The preferred target when it is still available (mail targets need an address).
    private var preferred: ReadingTarget? {
        model.readIn.flatMap { model.readingTargets.contains($0) ? $0 : nil }
            ?? (model.readingTargets.count == 1 ? .appleBooks : nil)
    }

    var body: some View {
        Section {
            Button {
                if let preferred { run(.read(preferred)) } else { isAsking = true }
            } label: {
                HStack {
                    Label(preferred.map(title) ?? "Read", systemImage: preferred.map(symbol) ?? "book")
                        .font(.body.weight(.semibold))
                    Spacer()
                    if working != nil { ProgressView() }
                }
            }
            Menu {
                ForEach(model.readingTargets.filter { $0 != preferred }) { target in
                    Button(title(target), systemImage: symbol(target)) { run(.read(target)) }
                }
                Button("Share file…", systemImage: "square.and.arrow.up") { run(.share) }
                if calibre != nil {
                    Button("Add to Calibre", systemImage: "books.vertical") { addToCalibre(allowDuplicate: false) }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        } footer: {
            if let message { Text(message) }
        }
        .disabled(working != nil)
        .confirmationDialog("Read in", isPresented: $isAsking, titleVisibility: .visible) {
            ForEach(model.readingTargets) { target in
                Button(title(target)) { run(.read(target)) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Calibre may already have this book",
            isPresented: Binding(get: { calibreDuplicates != nil }, set: { if !$0 { calibreDuplicates = nil } }),
            titleVisibility: .visible,
            presenting: calibreDuplicates
        ) { _ in
            Button("Add anyway") { addToCalibre(allowDuplicate: true) }
            Button("Cancel", role: .cancel) {}
        } message: { duplicates in
            Text(duplicates.joined(separator: "\n"))
        }
    }

    /// The best ebook of a service's ready release goes to Calibre, which files it under Author/Title; then the
    /// title, authors and description from this screen replace what Calibre read from the file (ISBN, publisher and
    /// language stay), and the cover too when the file had none.
    private func addToCalibre(allowDuplicate: Bool) {
        guard calibre != nil else { return }
        working = .calibre
        message = nil
        Task {
            defer { working = nil }
            do {
                let items = try await readyItems().filter { $0.backend != .calibre }
                guard let pick = BookFiles.pickAny(from: items) else {
                    message = items.isEmpty ? "No release is ready on a service yet." : BookFiles.Refusal.noBookFile.message(for: .appleBooks)
                    return
                }
                let url = try await localFile(for: pick)
                let summary = book.book ?? BookSummary(id: book.id, title: book.name, authors: book.author.map { [$0] } ?? [])
                let fileName = AppModel.calibreFileName(book: summary, fileName: pick.file.name)
                switch try await model.addToCalibre(file: url, fileName: fileName, book: book.book, allowDuplicate: allowDuplicate) {
                case .duplicates(let books): calibreDuplicates = books
                case let outcome: message = outcome.message
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func title(_ target: ReadingTarget) -> String { target.actionTitle }

    private func symbol(_ target: ReadingTarget) -> String {
        target.isMail ? "paperplane" : "book"
    }

    private func run(_ action: Action) {
        working = action
        message = nil
        Task {
            defer { working = nil }
            do {
                let items = try await readyItems()
                guard !items.isEmpty else {
                    message = "No release is ready on a service yet."
                    return
                }
                let pick: BookFiles.Pick
                switch action {
                case .read(let target):
                    switch BookFiles.pick(from: items, for: target) {
                    case .success(let found): pick = found
                    case .failure(let refusal):
                        message = refusal.message(for: target)
                        return
                    }
                // `.calibre` runs `addToCalibre`, never here.
                case .share, .calibre:
                    guard let found = BookFiles.pickAny(from: items) else {
                        message = BookFiles.Refusal.noBookFile.message(for: .appleBooks)
                        return
                    }
                    pick = found
                }
                let url = try await localFile(for: pick)
                if case .read(let target) = action, target.isMail {
                    send(url, pick: pick, to: target)
                } else {
                    SheetPresenter.share(url)
                    if case .read(.appleBooks) = action { message = "Pick Books in the share sheet." }
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Ready releases in the book's order; services that list items without files (Real-Debrid, Offcloud) are asked
    /// for the files one release at a time.
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

    /// The copy in Downloads when the user already downloaded this file, else the Read cache.
    private func localFile(for pick: BookFiles.Pick) async throws -> URL {
        if let record = model.downloads.records.first(where: {
            $0.state == .finished && $0.isSameFile(backend: pick.item.backend, itemID: pick.item.id, fileID: pick.file.id)
        }), let url = model.downloads.fileURL(for: record) {
            return url
        }
        guard let backend = model.backend(pick.item.backend) else {
            throw BackendError.api(message: "\(pick.item.backend.displayName) is no longer configured.")
        }
        return try await Self.cache.fetch(pick) {
            try await backend.downloadRequest(itemID: pick.item.id, fileID: pick.file.id)
        }
    }

    /// A Mail draft with the file attached; without a Mail account, the share sheet and the address on the clipboard.
    private func send(_ url: URL, pick: BookFiles.Pick, to target: ReadingTarget) {
        let name = (pick.file.name as NSString).lastPathComponent
        let recipient = model.mailAddress(for: target)
        guard MFMailComposeViewController.canSendMail() else {
            UIPasteboard.general.string = recipient
            SheetPresenter.share(url)
            message = "Mail has no account on this iPhone. The address is copied: share the file to your mail app and paste it as the recipient."
            return
        }
        do {
            let data = try Data(contentsOf: url)
            SheetPresenter.mail(to: recipient, subject: book.name, data: data,
                                mimeType: BookFiles.mimeType(of: name), fileName: name) { result in
                switch result {
                case .sent:
                    message = ["Sent to \(recipient).", target.deliveryNote].filter { !$0.isEmpty }.joined(separator: " ")
                case .failed:
                    message = "Mail could not send it. Try again, or use Share file."
                default:
                    break
                }
            }
        } catch {
            message = error.localizedDescription
        }
    }
}

/// Presents the share and Mail sheets from UIKit's top view controller. A SwiftUI `.sheet` inside the book screen's
/// list was dismissed as soon as the list redrew (a library refresh during the first download).
@MainActor
enum SheetPresenter {
    /// Mail keeps only a weak delegate.
    private static var mailDelegate: MailDelegate?

    static func share(_ url: URL) {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        present(controller)
    }

    /// Mail's compose sheet with the file attached; the user taps Send (iOS never sends mail for an app).
    static func mail(
        to recipient: String,
        subject: String,
        data: Data,
        mimeType: String,
        fileName: String,
        onFinish: @escaping @MainActor (MFMailComposeResult) -> Void
    ) {
        let controller = MFMailComposeViewController()
        let delegate = MailDelegate { result in
            mailDelegate = nil
            onFinish(result)
        }
        mailDelegate = delegate
        controller.mailComposeDelegate = delegate
        controller.setToRecipients([recipient])
        controller.setSubject(subject)
        controller.addAttachmentData(data, mimeType: mimeType, fileName: fileName)
        present(controller)
    }

    private static func present(_ controller: UIViewController) {
        guard var top = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first?.rootViewController
        else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        // iPad: the share sheet is a popover and needs an anchor.
        controller.popoverPresentationController?.sourceView = top.view
        controller.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        controller.popoverPresentationController?.permittedArrowDirections = []
        top.present(controller, animated: true)
    }

    @MainActor private final class MailDelegate: NSObject, @preconcurrency MFMailComposeViewControllerDelegate {
        let onFinish: @MainActor (MFMailComposeResult) -> Void

        init(onFinish: @escaping @MainActor (MFMailComposeResult) -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: (any Error)?
        ) {
            controller.dismiss(animated: true)
            onFinish(result)
        }
    }
}
