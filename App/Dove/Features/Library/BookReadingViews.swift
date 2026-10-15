import DoveKit
import MessageUI
import SwiftUI
import UIKit

/// "Read" on a book screen: the best file of the book's ready releases (`BookFiles`) goes to Apple Books (through the
/// share sheet: Books has no URL scheme for files) or to Kindle (a Mail draft to the Send to Kindle address).
/// The file is downloaded to Caches once (`BookFileCache`), or taken from Downloads when it is already there.
struct BookReadSection: View {
    @Environment(AppModel.self) private var model
    let book: BookTitle
    @State private var working: Action?
    @State private var message: String?
    @State private var sharedFile: SharedFile?
    @State private var mail: KindleMail?
    @State private var isAsking = false

    enum Action: Hashable {
        case read(ReadingTarget)
        case share
    }

    private static let cache = BookFileCache()

    /// The preferred target when it is still available (Kindle needs an address).
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
        .sheet(item: $sharedFile) { ShareSheet(url: $0.url).ignoresSafeArea() }
        .sheet(item: $mail) { draft in
            KindleMailView(mail: draft) { result in
                mail = nil
                switch result {
                case .sent:
                    message = "Sent to \(draft.recipient). Amazon delivers it in a few minutes."
                case .failed:
                    message = "Mail could not send it. Try again, or use Share file."
                default:
                    break
                }
            }
            .ignoresSafeArea()
        }
    }

    private func title(_ target: ReadingTarget) -> String {
        target == .kindle ? "Send to Kindle" : "Open in Apple Books"
    }

    private func symbol(_ target: ReadingTarget) -> String {
        target == .kindle ? "paperplane" : "book"
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
                case .share:
                    guard let found = BookFiles.pickAny(from: items) else {
                        message = BookFiles.Refusal.noBookFile.message(for: .appleBooks)
                        return
                    }
                    pick = found
                }
                let url = try await localFile(for: pick)
                if case .read(.kindle) = action {
                    sendToKindle(url, pick: pick)
                } else {
                    sharedFile = SharedFile(url: url)
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
    private func sendToKindle(_ url: URL, pick: BookFiles.Pick) {
        let name = (pick.file.name as NSString).lastPathComponent
        guard MFMailComposeViewController.canSendMail() else {
            UIPasteboard.general.string = model.kindleAddress
            sharedFile = SharedFile(url: url)
            message = "Mail has no account on this iPhone. The Kindle address is copied: share the file to your mail app and paste it as the recipient."
            return
        }
        do {
            let data = try Data(contentsOf: url)
            mail = KindleMail(recipient: model.kindleAddress, subject: book.name, data: data,
                              mimeType: BookFiles.mimeType(of: name), fileName: name)
        } catch {
            message = error.localizedDescription
        }
    }
}

struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct KindleMail: Identifiable {
    let id = UUID()
    let recipient: String
    let subject: String
    let data: Data
    let mimeType: String
    let fileName: String
}

/// Mail's compose sheet with the book attached; the user taps Send (iOS never sends mail for an app).
struct KindleMailView: UIViewControllerRepresentable {
    let mail: KindleMail
    let onFinish: (MFMailComposeResult) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([mail.recipient])
        controller.setSubject(mail.subject)
        controller.addAttachmentData(mail.data, mimeType: mail.mimeType, fileName: mail.fileName)
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (MFMailComposeResult) -> Void

        init(onFinish: @escaping (MFMailComposeResult) -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: (any Error)?
        ) {
            onFinish(result)
        }
    }
}

/// Settings › Books: where Read goes, and the Send to Kindle address.
struct BookSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var cacheBytes: Int64?

    private var addressIsValid: Bool { address.isEmpty || BookFiles.isValidAddress(address) }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Read in", selection: $model.readIn) {
                    Text("Ask every time").tag(ReadingTarget?.none)
                    ForEach(model.readingTargets) { Text($0.displayName).tag(Optional($0)) }
                }
            } footer: {
                Text("Read sends the book's EPUB, or its PDF when there is no EPUB. Apple Books opens through the share sheet. Neither takes MOBI or AZW3: use Share file for those.")
            }

            Section {
                TextField("name@kindle.com", text: $address)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(save)
            } header: {
                Text("Send to Kindle")
            } footer: {
                if addressIsValid {
                    Text("Find it on Amazon: Manage Your Content and Devices › Preferences › Personal Document Settings. Add the address Mail sends from to the Approved Personal Document E-mail List there, or Amazon drops the book. Up to 50 MB a book.")
                } else {
                    Text("That does not look like an e-mail address.").foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent("Books opened with Read", value: cacheBytes.map { $0.formatted(.byteCount(style: .file)) } ?? "…")
                Button("Clear", role: .destructive) {
                    BookFileCache().removeAll()
                    cacheBytes = 0
                }
                .disabled(cacheBytes == 0)
            } footer: {
                Text("Kept so a second Read does not download the book again. iOS may clear them when space runs low.")
            }
        }
        .navigationTitle("Books")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            address = model.kindleAddress
            cacheBytes = BookFileCache().size()
        }
        .onDisappear(perform: save)
    }

    private func save() {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty || BookFiles.isValidAddress(trimmed), trimmed != model.kindleAddress else { return }
        model.kindleAddress = trimmed
        if trimmed.isEmpty, model.readIn == .kindle { model.readIn = nil }
    }
}
