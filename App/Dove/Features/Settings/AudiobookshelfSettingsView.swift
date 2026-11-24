import DoveAppCore
import DoveKit
import SwiftUI

/// Settings › Audiobookshelf: the server's address, an API key, and the library audiobooks are sent to.
struct AudiobookshelfSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var url = ""
    @State private var token = ""
    @State private var libraryID = ""
    @State private var account: AudiobookshelfBackend.Account?
    @State private var status: SettingsStatus?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                TextField("http://192.168.1.10:13378", text: $url)
                    .keyboardType(.URL)
                    .textContentType(.URL)
            } header: {
                Text("Address")
            } footer: {
                Text("The address you open Audiobookshelf at, with its path when it has one (http://nas.local:13378/audiobookshelf). iOS allows plain http only on the local network (an IP address or a .local name); away from home use https.")
            }
            Section {
                SecureField("API key", text: $token)
                    .textContentType(.password)
            } header: {
                Text("API key")
            } footer: {
                Text("Audiobookshelf › Settings › API Keys › Add API Key (server 2.26 or later), for your own user. Sending needs that user's \"Can Upload\" permission (Settings › Users); listing and downloading work without it.")
            }
            if let account, !account.bookLibraries.isEmpty {
                Section {
                    Picker("Send to", selection: $libraryID) {
                        ForEach(account.bookLibraries) { library in
                            Text(library.name).tag(library.id)
                        }
                    }
                    .onChange(of: libraryID) { _, id in
                        try? model.keychain.set(id.isEmpty ? nil : id, for: .audiobookshelfLibrary)
                        model.reloadBackends()
                    }
                    LabeledContent("Account", value: account.username)
                    LabeledContent("May send", value: account.canUpload ? "Yes" : "No")
                } header: {
                    Text("Library")
                } footer: {
                    Text(account.canUpload
                         ? "Audiobooks go to the library's first folder, filed by the server under Author/Title."
                         : "This account may not upload. Turn on \"Can Upload\" for it in Audiobookshelf › Settings › Users to send audiobooks.")
                }
            }
            Section {
                Button(action: saveAndTest) {
                    HStack {
                        Text("Save and test connection")
                        if isTesting { Spacer(); ProgressView() }
                    }
                }
                .disabled(isTesting)
                if let status { SettingsStatusView(status: status) }
            } footer: {
                Text("Dove lists what the server holds, marks those books \"In library\" and sends audiobooks there. Listening, progress and editing stay in Audiobookshelf's own apps.")
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle("Audiobookshelf")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        url = (try? model.keychain.get(.audiobookshelfURL)) ?? ""
        token = (try? model.keychain.get(.audiobookshelfToken)) ?? ""
        libraryID = (try? model.keychain.get(.audiobookshelfLibrary)) ?? ""
        if model.backend(.audiobookshelf) != nil { loadAccount(reportSuccess: false) }
    }

    /// "nas.local:13378/" → "http://nas.local:13378"; no trailing slash.
    private static func address(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !text.isEmpty, !text.contains("://") { text = "http://" + text }
        return text
    }

    private func saveAndTest() {
        let address = Self.address(url)
        let key = token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try model.keychain.set(address.isEmpty ? nil : address, for: .audiobookshelfURL)
            try model.keychain.set(key.isEmpty ? nil : key, for: .audiobookshelfToken)
        } catch {
            status = .failure("Keychain error: \(error)")
            return
        }
        url = address
        token = key
        model.reloadBackends()
        guard model.backend(.audiobookshelf) != nil else {
            account = nil
            status = address.isEmpty && key.isEmpty
                ? .note("Audiobookshelf removed.")
                : .failure(address.isEmpty || URL(string: address)?.host() == nil ? "Enter an address like http://192.168.1.10:13378." : "Enter an API key.")
            Task { await model.library.refresh(using: model) }
            return
        }
        loadAccount(reportSuccess: true)
    }

    private func loadAccount(reportSuccess: Bool) {
        guard let shelf = model.backend(.audiobookshelf) as? AudiobookshelfBackend else { return }
        if reportSuccess { status = .testing }
        isTesting = true
        Task {
            defer { isTesting = false }
            do {
                try await shelf.validateCredentials()
                let found = try await shelf.account()
                account = found
                if !found.bookLibraries.contains(where: { $0.id == libraryID }), let first = found.bookLibraries.first {
                    libraryID = first.id
                }
                if reportSuccess {
                    status = .success(found.canUpload ? "Connected as \(found.username)." : "Connected as \(found.username), without permission to upload.")
                    await model.library.refresh(using: model)
                }
            } catch {
                status = SettingsStatus(error)
            }
        }
    }
}
