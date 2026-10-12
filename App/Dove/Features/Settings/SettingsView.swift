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

                Section("Usenet") {
                    Text("nzbdav: stage 3").foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink {
                        AddonsView()
                    } label: {
                        LabeledContent("Stremio addons", value: "\(model.addonEntries.count)")
                    }
                } header: {
                    Text("Search")
                } footer: {
                    Text("Titles, metadata and sources come from your Stremio addons.")
                }

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
