import DoveKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Form {
                Section("Debrid") {
                    APIKeyRow(backend: .realDebrid, key: .realDebridAPIKey)
                    APIKeyRow(backend: .torBox, key: .torBoxAPIKey)
                    APIKeyRow(backend: .offcloud, key: .offcloudAPIKey)
                }

                Section {
                    NavigationLink {
                        DebridPriorityView()
                    } label: {
                        LabeledContent("Priority", value: model.debridOrder.map(\.displayName).joined(separator: " → "))
                    }
                } footer: {
                    Text("Torrents and links go to the first service. If it fails, Dove tries the next one.")
                }

                Section {
                    NavigationLink {
                        NzbdavSettingsView()
                    } label: {
                        LabeledContent("nzbdav", value: model.isConfigured(.nzbdav) ? "Connected" : "Not set up")
                    }
                    TorBoxUsenetToggle()
                } header: {
                    Text("Usenet")
                } footer: {
                    Text("NZBs go to nzbdav first, then to TorBox if your TorBox plan includes Usenet.")
                }

                Section {
                    NavigationLink {
                        AddonsView()
                    } label: {
                        LabeledContent("Stremio addons", value: "\(model.addonEntries.count)")
                    }
                    NavigationLink {
                        NewznabIndexersView()
                    } label: {
                        LabeledContent("Indexers", value: "\(model.newznabIndexers.filter(\.enabled).count)")
                    }
                } header: {
                    Text("Search")
                } footer: {
                    Text("Sources (and titles, without a TMDB key) come from your Stremio addons. Indexers (Newznab for Usenet, Torznab for torrents) are searched from your phone and add sources, and power Search › Other.")
                }

                Section {
                    TMDBKeyRow()
                } header: {
                    Text("Metadata")
                } footer: {
                    Text("With a TMDB key, search, posters, seasons and episodes come from TMDB first; your addons answer when TMDB cannot. Get a free key at themoviedb.org › Settings › API (the API key or the read access token).")
                }

                FilesLocationSection()
            }
            .navigationTitle("Settings")
        }
    }
}

/// API key field for one service: saves to the Keychain and tests the connection.
private struct APIKeyRow: View {
    @Environment(AppModel.self) private var model
    let backend: BackendID
    let key: CredentialKey
    @State private var value = ""
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("\(backend.displayName) API key", text: $value)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(saveAndTest)
            Button("Save and test connection", action: saveAndTest)
                .font(.callout)
            if let status { Text(status).font(.footnote) }
        }
        .onAppear {
            value = (try? model.keychain.get(key)) ?? ""
        }
    }

    private func saveAndTest() {
        do {
            try model.keychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: key)
        } catch {
            status = "Keychain error: \(error)"
            return
        }
        model.reloadBackends()
        guard let service = model.backend(backend) else {
            status = "Key removed."
            return
        }
        status = "Testing…"
        Task {
            do {
                try await service.validateCredentials()
                status = "✅ Connected to \(backend.displayName)."
            } catch {
                status = "❌ \(error.localizedDescription)"
            }
        }
    }
}

/// TMDB key field: validated against TMDB before it is saved.
private struct TMDBKeyRow: View {
    @Environment(AppModel.self) private var model
    @State private var value = ""
    @State private var status: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("TMDB API key or read access token", text: $value)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(save)
            Button("Save and test", action: save)
                .font(.callout)
                .disabled(isSaving)
            if let status { Text(status).font(.footnote) }
        }
        .onAppear { value = model.tmdbKey }
    }

    private func save() {
        isSaving = true
        status = value.isEmpty ? nil : "Testing…"
        Task {
            do {
                try await model.saveTMDBKey(value)
                status = value.isEmpty ? "Key removed." : "✅ TMDB key works."
            } catch {
                status = "❌ \(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}

/// The "Dove" location in the Files app: re-register it when Files shows an error next to it.
private struct FilesLocationSection: View {
    @State private var status: String?
    @State private var isResetting = false

    var body: some View {
        Section {
            Button("Reset Files location") {
                isResetting = true
                Task {
                    do {
                        try await FilesLocation.reset()
                        status = "Done. Open Files, tap Dove and turn it on."
                    } catch {
                        status = error.localizedDescription
                    }
                    isResetting = false
                }
            }
            .disabled(isResetting)
            if let status {
                Text(status).foregroundStyle(.secondary)
            }
        } header: {
            Text("Files app")
        } footer: {
            Text("Your services appear in Files under Locations › Dove. If Files shows an error there, reset it: Files forgets what it knew and lists everything again.")
        }
    }
}
