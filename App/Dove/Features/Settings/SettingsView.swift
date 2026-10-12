import DoveKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    APIKeyRow(backend: .realDebrid, key: .realDebridAPIKey)
                    APIKeyRow(backend: .torBox, key: .torBoxAPIKey)
                } header: {
                    Text("Debrid")
                } footer: {
                    Text("Offcloud is coming next.")
                }

                Section("Defaults") {
                    Picker("Torrents and links go to", selection: $model.preferredDebrid) {
                        ForEach(BackendID.allCases.filter { !$0.isUsenet }) { Text($0.displayName).tag($0) }
                    }
                }

                Section("Usenet") {
                    Text("nzbdav: stage 3").foregroundStyle(.secondary)
                }

                Section("Search") {
                    Text("Stremio addons, AIOStreams and TMDB: stage 2").foregroundStyle(.secondary)
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
