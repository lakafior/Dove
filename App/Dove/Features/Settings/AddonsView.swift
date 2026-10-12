import DoveKit
import SwiftUI

/// Stremio addons in the user's order: drag to reorder, swipe or tap ⊖ to remove, + to add a manifest URL.
struct AddonsView: View {
    @Environment(AppModel.self) private var model
    @State private var isAskingForURL = false
    @State private var newURL = ""
    @State private var isAdding = false
    @State private var addError: String?

    var body: some View {
        List {
            Section {
                ForEach(model.addonEntries) { entry in
                    AddonRow(entry: entry)
                }
                .onMove { model.moveAddons(from: $0, to: $1) }
                .onDelete { model.removeAddons(at: $0) }
            } footer: {
                Text("The first addon that can search finds titles; every addon with streams adds sources. Addon URLs often contain your keys, so Dove keeps them in the Keychain.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .overlay {
            if model.addonEntries.isEmpty {
                ContentUnavailableView(
                    "No addons",
                    systemImage: "puzzlepiece.extension",
                    description: Text("Tap + and paste a manifest URL, e.g. from AIOStreams, AIOMetadata or Cinemeta.")
                )
            }
        }
        .navigationTitle("Stremio addons")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isAdding {
                    ProgressView()
                } else {
                    Button("Add addon", systemImage: "plus") {
                        newURL = ""
                        isAskingForURL = true
                    }
                }
            }
        }
        .alert("Add addon", isPresented: $isAskingForURL) {
            TextField("https://…/manifest.json", text: $newURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Add", action: add)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paste the addon's manifest URL.")
        }
        .alert("Could not add the addon", isPresented: Binding(get: { addError != nil }, set: { if !$0 { addError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(addError ?? "")
        }
    }

    private func add() {
        let text = newURL
        guard !text.isEmpty else { return }
        isAdding = true
        Task {
            do {
                try await model.addAddon(text)
            } catch {
                addError = error.localizedDescription
            }
            isAdding = false
        }
    }
}

private struct AddonRow: View {
    let entry: AppModel.AddonEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.addon?.manifest.name ?? entry.url.host() ?? "Addon")
            Group {
                if let manifest = entry.addon?.manifest {
                    Text(roles(of: manifest).joined(separator: " · "))
                } else if let error = entry.error {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("Loading…")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func roles(of manifest: StremioManifest) -> [String] {
        var roles: [String] = []
        if manifest.canSearch { roles.append("Search") }
        if manifest.provides("meta") { roles.append("Metadata") }
        if manifest.provides("stream") { roles.append("Streams") }
        return roles.isEmpty ? ["Nothing Dove uses"] : roles
    }
}

/// Password of the user's AIOStreams configuration, for its Search API.
struct AIOStreamsPasswordRow: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var saved = false

    var body: some View {
        HStack {
            SecureField("AIOStreams password", text: $password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(save)
            Button(saved ? "Saved" : "Save", action: save)
                .disabled(saved)
        }
        .onAppear {
            password = model.aioStreamsPassword
            saved = !password.isEmpty
        }
        .onChange(of: password) { saved = false }
    }

    private func save() {
        model.aioStreamsPassword = password
        saved = true
    }
}
