import DoveKit
import SwiftUI

/// nzbdav connection: server URL, SABnzbd API key, WebDAV login. All four live in the Keychain.
struct NzbdavSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var url = ""
    @State private var apiKey = ""
    @State private var user = ""
    @State private var password = ""
    @State private var status: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                TextField("https://nzbdav.example.com", text: $url)
                    .keyboardType(.URL)
                    .textContentType(.URL)
            } header: {
                Text("Server")
            } footer: {
                Text("The address you open nzbdav at. The API and WebDAV are on the same address.")
            }
            Section {
                SecureField("API key", text: $apiKey)
            } header: {
                Text("SABnzbd API")
            } footer: {
                Text("nzbdav → Settings → SABnzbd → API key.")
            }
            Section {
                TextField("User", text: $user)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
            } header: {
                Text("WebDAV")
            } footer: {
                Text("nzbdav → Settings → WebDAV. Dove lists and downloads files with it; Infuse gets it inside the link it plays.")
            }
            Section {
                Button(action: saveAndTest) {
                    HStack {
                        Text("Save and test connection")
                        if isTesting { Spacer(); ProgressView() }
                    }
                }
                .disabled(isTesting)
                if let status { Text(status).font(.footnote) }
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle("nzbdav")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        url = (try? model.keychain.get(.nzbdavURL)) ?? ""
        apiKey = (try? model.keychain.get(.nzbdavAPIKey)) ?? ""
        user = (try? model.keychain.get(.nzbdavWebDAVUser)) ?? ""
        password = (try? model.keychain.get(.nzbdavWebDAVPassword)) ?? ""
    }

    private func saveAndTest() {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        do {
            try model.keychain.set(trimmedURL, for: .nzbdavURL)
            try model.keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: .nzbdavAPIKey)
            try model.keychain.set(user.trimmingCharacters(in: .whitespacesAndNewlines), for: .nzbdavWebDAVUser)
            try model.keychain.set(password, for: .nzbdavWebDAVPassword)
        } catch {
            status = "Keychain error: \(error)"
            return
        }
        model.reloadBackends()
        guard let nzbdav = model.backend(.nzbdav) else {
            status = trimmedURL.isEmpty && apiKey.isEmpty ? "nzbdav removed." : "Fill in all four fields."
            return
        }
        status = "Testing…"
        isTesting = true
        Task {
            defer { isTesting = false }
            do {
                try await nzbdav.validateCredentials()
                status = "✅ Connected: API key and WebDAV login work."
            } catch {
                status = "❌ \(error.localizedDescription)"
            }
        }
    }
}

/// "My TorBox plan includes Usenet": NZBs may go to TorBox (after nzbdav).
struct TorBoxUsenetToggle: View {
    @Environment(AppModel.self) private var model
    @State private var isOn = false

    var body: some View {
        Toggle("TorBox Usenet", isOn: $isOn)
            .disabled(!model.isConfigured(.torBox))
            .onAppear { isOn = (try? model.keychain.get(.torBoxUsenet)) == "1" }
            .onChange(of: isOn) {
                try? model.keychain.set(isOn ? "1" : "", for: .torBoxUsenet)
                model.reloadBackends()
            }
    }
}

/// Dove's own Newznab (Usenet) and Torznab (torrent) indexers; Prowlarr, NZBHydra and Jackett count as one each.
/// Searched from the phone, so indexers that block shared AIOStreams servers still answer.
struct NewznabIndexersView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: NewznabIndexer?
    @State private var usage: [NewznabIndexer.ID: NewznabSearch.Usage] = [:]
    @State private var message: String?

    var body: some View {
        List {
            if let message {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            Section {
                ForEach(model.newznabIndexers) { indexer in
                    Button {
                        editing = indexer
                    } label: {
                        row(indexer)
                    }
                    .tint(.primary)
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(indexer) }
                    }
                }
            } footer: {
                Text("Dove asks these from your phone when you open sources, and keeps answers for an hour. Set a daily limit for free accounts: Dove stops there, and also when an indexer says its limit is reached.")
            }
            Section {
                Button("Add indexer", systemImage: "plus") {
                    editing = NewznabIndexer(name: "", url: URL(string: "https://")!, apiKey: "")
                }
            }
        }
        .navigationTitle("Indexers")
        .sheet(item: $editing) { indexer in
            NavigationStack {
                NewznabIndexerEditor(indexer: indexer) { saved in
                    save(saved)
                }
            }
        }
        .task(id: model.newznabIndexers) { await loadUsage() }
    }

    private func row(_ indexer: NewznabIndexer) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(indexer.name).foregroundStyle(indexer.enabled ? .primary : .secondary)
                if indexer.kind == .torznab { Text("Torznab").font(.caption).foregroundStyle(.secondary) }
                if !indexer.enabled { Text("off").font(.caption).foregroundStyle(.secondary) }
            }
            Text(usageText(indexer)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func usageText(_ indexer: NewznabIndexer) -> String {
        let hits = usage[indexer.id]?.hits ?? 0
        if usage[indexer.id]?.blocked == true { return "Limit reached today" }
        if let limit = indexer.dailyLimit { return "\(hits) of \(limit) API hits today" }
        return "\(hits) API hits today"
    }

    private func loadUsage() async {
        var result: [NewznabIndexer.ID: NewznabSearch.Usage] = [:]
        for indexer in model.newznabIndexers {
            result[indexer.id] = await model.newznab.usage(of: indexer)
        }
        usage = result
    }

    private func save(_ indexer: NewznabIndexer) {
        var list = model.newznabIndexers
        if let index = list.firstIndex(where: { $0.id == indexer.id }) { list[index] = indexer } else { list.append(indexer) }
        persist(list)
    }

    private func delete(_ indexer: NewznabIndexer) {
        persist(model.newznabIndexers.filter { $0.id != indexer.id })
    }

    private func persist(_ list: [NewznabIndexer]) {
        do {
            try model.saveNewznabIndexers(list)
            message = nil
        } catch {
            message = "Keychain error: \(error)"
        }
    }
}

private struct NewznabIndexerEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let indexer: NewznabIndexer
    let onSave: (NewznabIndexer) -> Void

    @State private var kind: NewznabIndexer.Kind = .newznab
    @State private var name = ""
    @State private var url = ""
    @State private var apiKey = ""
    @State private var limit = ""
    @State private var enabled = true
    @State private var status: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $kind) {
                    ForEach(NewznabIndexer.Kind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                TextField("Name", text: $name)
                TextField(kind == .newznab ? "https://api.indexer.example" : "http://jackett.lan:9117/api/v2.0/indexers/all/results/torznab", text: $url)
                    .keyboardType(.URL)
                SecureField("API key", text: $apiKey)
            } footer: {
                Text(kind == .newznab
                    ? "The indexer's address (a full …/api link works too) and your API key from its profile page. Results are NZBs for nzbdav or TorBox Usenet."
                    : "The Torznab feed from Jackett (…/torznab) or Prowlarr (…/<id>/api) and its API key. Results are torrents for your debrid services; Dove fetches .torrent links on the phone, so a local address works.")
            }
            Section {
                TextField("Daily API limit (optional)", text: $limit)
                    .keyboardType(.numberPad)
                Toggle("Search this indexer", isOn: $enabled)
            }
            Section {
                Button {
                    test()
                } label: {
                    HStack {
                        Text("Test")
                        if isTesting { Spacer(); ProgressView() }
                    }
                }
                .disabled(isTesting || draft == nil)
                if let status { Text(status).font(.footnote) }
            } footer: {
                Text("A test uses two API hits.")
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle(indexer.name.isEmpty ? "New indexer" : indexer.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if let draft { onSave(draft) }
                    dismiss()
                }
                .disabled(draft == nil)
            }
        }
        .onAppear {
            kind = indexer.kind
            name = indexer.name
            // A new indexer starts empty; an existing one shows its address (and a non-standard API path).
            url = indexer.apiKey.isEmpty ? "" : indexer.url.absoluteString + (indexer.apiPath == "/api" ? "" : indexer.apiPath)
            apiKey = indexer.apiKey
            limit = indexer.dailyLimit.map(String.init) ?? ""
            enabled = indexer.enabled
        }
    }

    /// Nil until the address and key make sense.
    private var draft: NewznabIndexer? {
        guard let target = NewznabIndexer.normalized(url: url) else { return nil }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        var result = indexer
        result.kind = kind
        result.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? (target.url.host() ?? "Indexer") : name
        result.url = target.url
        result.apiPath = target.apiPath
        result.apiKey = key
        result.dailyLimit = Int(limit.trimmingCharacters(in: .whitespaces))
        result.enabled = enabled
        return result
    }

    private func test() {
        guard let draft else { return }
        isTesting = true
        status = "Testing…"
        Task {
            defer { isTesting = false }
            do {
                try await model.newznab.test(draft)
                status = "✅ The indexer answered a search."
            } catch {
                status = "❌ \(error.localizedDescription)"
            }
        }
    }
}
