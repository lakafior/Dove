import DoveAppCore
import DoveKit
import SwiftUI

/// Settings › Reading: where Read goes, and the addresses books are mailed to.
struct ReadingSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var addresses = MailAddresses()

    private static let mailTargets = ReadingTarget.allCases.filter(\.isMail)

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Read in", selection: $model.readIn) {
                    Text("Ask every time").tag(ReadingTarget?.none)
                    ForEach(model.readingTargets) { Text($0.displayName).tag(Optional($0)) }
                }
            } footer: {
                Text("Read sends the best file the reader takes: EPUB first, then PDF. Apple Books opens through the share sheet; the others get a Mail draft. Apple Books and Kindle do not take MOBI or AZW3: use Share file for those.")
            }

            ForEach(Self.mailTargets) { target in
                addressSection(target)
            }
        }
        .navigationTitle("Reading")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            for target in Self.mailTargets { addresses[target] = model.mailAddress(for: target) }
        }
        .onDisappear(perform: saveAll)
    }

    private func addressSection(_ target: ReadingTarget) -> some View {
        let address = addresses[target]
        let isValid = address.isEmpty || BookFiles.isValidAddress(address)
        return Section {
            TextField(target.addressPlaceholder, text: $addresses[target])
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit { save(target) }
        } header: {
            Text(target.actionTitle)
        } footer: {
            if isValid {
                Text(Self.help(for: target))
            } else {
                Text("That does not look like an e-mail address.").foregroundStyle(.red)
            }
        }
    }

    private static func help(for target: ReadingTarget) -> String {
        switch target {
        case .kindle:
            "Find it on Amazon: Manage Your Content and Devices › Preferences › Personal Document Settings. Add the address Mail sends from to the Approved Personal Document E-mail List there, or Amazon drops the book. Up to 50 MB a book."
        case .pocketBook:
            "Set it up on the reader: Send-to-PocketBook in its applications (needs a PocketBook Cloud account). The first book from a new sender address may need your confirmation by e-mail. EPUB, FB2, PDF, MOBI, AZW3, DjVu and comics."
        case .email:
            "Any address: your own inbox, or another reader's mail service. Takes any ebook format, EPUB first. Kobo has no such address: use Share file and its Dropbox or Google Drive library instead."
        case .appleBooks:
            ""
        }
    }

    private func saveAll() {
        for target in Self.mailTargets { save(target) }
    }

    private func save(_ target: ReadingTarget) {
        let trimmed = addresses[target].trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty || BookFiles.isValidAddress(trimmed), trimmed != model.mailAddress(for: target) else { return }
        model.setMailAddress(trimmed, for: target)
    }
}
