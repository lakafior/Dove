import DoveAppCore
import DoveKit
import SwiftUI

/// Settings › Movies and TV: the TMDB key, validated against TMDB before it is saved.
struct TMDBSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var value = ""
    @State private var status: SettingsStatus?

    var body: some View {
        Form {
            Section {
                LabeledContent("TMDB", value: model.addonSet.tmdb != nil ? "Connected" : "Needs a key")
                LabeledContent("Metadata addons", value: "Free")
            } header: {
                Text("Sources")
            } footer: {
                Text("With a key, search, posters, seasons and episodes come from TMDB first; your addons answer when TMDB cannot. Without one, the addons do it all.")
            }
            Section {
                SecureField("API key or read access token", text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(save)
                Button(action: save) {
                    HStack {
                        Text("Save and test")
                        if status == .testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(status == .testing)
                if let status, status != .testing { SettingsStatusView(status: status) }
            } header: {
                Text("TMDB key")
            } footer: {
                Text("Get a free key at themoviedb.org › Settings › API (the API key or the read access token).")
            }
        }
        .navigationTitle("Movies and TV")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { value = model.tmdbKey }
    }

    private func save() {
        status = .testing
        Task {
            do {
                try await model.saveTMDBKey(value)
                status = value.isEmpty ? .note("Key removed.") : .success("TMDB key works.")
            } catch {
                status = SettingsStatus(error)
            }
        }
    }
}
