import DoveAppCore
import DoveKit
import SwiftUI

/// Stremio addons in the user's order: tap for details (AIOStreams options live there), swipe to remove,
/// Edit to reorder, + to add a manifest URL.
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
                    NavigationLink {
                        AddonDetailView(entryID: entry.id)
                    } label: {
                        AddonRow(entry: entry)
                    }
                }
                .onMove { model.moveAddons(from: $0, to: $1) }
                .onDelete { model.removeAddons(at: $0) }
            } footer: {
                Text("The first addon that can search finds titles; every addon with streams adds sources. Addon URLs often contain your keys, so Dove keeps them in the Keychain.")
            }
        }
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
            if model.addonEntries.count > 1 {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
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

struct AddonRow: View {
    let entry: AppModel.AddonEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.addon?.manifest.name ?? entry.url.host() ?? "Addon")
            Group {
                if let manifest = entry.addon?.manifest {
                    Text((roles(of: manifest) + (entry.isAIOStreams ? ["AIOStreams"] : [])).joined(separator: " · "))
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

/// Password of the user's AIOStreams configuration, for its Search API. Checked before it is saved.
struct AIOStreamsPasswordRow: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var state: SaveState = .idle

    enum SaveState: Equatable {
        case idle, checking, saved
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField("AIOStreams password", text: $password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(save)
                switch state {
                case .checking: ProgressView()
                case .saved: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                default: Button("Save", action: save)
                }
            }
            if case .failed(let message) = state {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        }
        .onAppear {
            password = model.aioStreamsPassword
            state = password.isEmpty ? .idle : .saved
        }
        // Loading the stored password on appear is not an edit.
        .onChange(of: password) {
            if state != .checking { state = password == model.aioStreamsPassword && !password.isEmpty ? .saved : .idle }
        }
    }

    private func save() {
        state = .checking
        Task {
            do {
                try await model.saveAIOStreamsPassword(password)
                state = password.isEmpty ? .idle : .saved
            } catch BackendError.unauthorized {
                state = .failed("Wrong password for this AIOStreams configuration.")
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

/// AIOStreams config variant for Dove's searches: pick one the configuration defines, or let Dove add its own.
/// Separate rows on purpose: a button in the picker's row would open the picker instead.
struct AIOStreamsVariantSection: View {
    @Environment(AppModel.self) private var model
    @State private var variants: [AIOStreamsSearch.Variant] = []
    @State private var loadError: String?
    @State private var confirmCreate = false
    @State private var isCreating = false
    @State private var createError: String?

    private var hasDoveVariant: Bool {
        variants.contains { $0.id == AIOStreamsSearch.unfilteredVariantID }
    }

    private var hasPassword: Bool { !model.aioStreamsPassword.isEmpty }

    var body: some View {
        @Bindable var model = model
        Section {
            Picker("Variant", selection: $model.aioStreamsVariant) {
                Text("None").tag("")
                ForEach(variants) { variant in
                    Text(variant.displayName + (variant.enabled ? "" : " — disabled")).tag(variant.id)
                }
                // Keep a stored id visible even if the configuration no longer has it.
                if !model.aioStreamsVariant.isEmpty, !variants.contains(where: { $0.id == model.aioStreamsVariant }) {
                    Text("\(model.aioStreamsVariant) — missing").tag(model.aioStreamsVariant)
                }
            }
            .disabled(!hasPassword)

            if hasPassword, loadError == nil {
                Button {
                    confirmCreate = true
                } label: {
                    HStack {
                        Label(
                            hasDoveVariant ? "Update Dove's variant" : "Create a variant for Dove",
                            systemImage: "wand.and.stars"
                        )
                        if isCreating {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isCreating)
            }

            if let message = createError ?? warning {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(createError != nil ? .red : .orange)
            }
        } header: {
            Text("Variant")
        } footer: {
            Text("Your Stremio filters also apply to Dove. Dove's variant lifts them and leaves out Usenet and HTTP addons (Dove searches Usenet with its own indexers), for Dove's searches only; Stremio keeps your configuration as it is. Update it after you add or remove addons.")
        }
        .task(id: model.aioStreamsPasswordRevision) { await load() }
        .confirmationDialog(
            hasDoveVariant ? "Update Dove's variant in AIOStreams?" : "Add a variant to AIOStreams?",
            isPresented: $confirmCreate,
            titleVisibility: .visible
        ) {
            Button(hasDoveVariant ? "Update" : "Add \"\(AIOStreamsSearch.unfilteredVariantID)\" variant") { create() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The \"\(AIOStreamsSearch.unfilteredVariantID)\" variant lifts all filters and result limits and turns off addons that only bring Usenet or HTTP streams, only for Dove's searches. Your base configuration and Stremio stay as they are. You can edit or delete it in AIOStreams (Miscellaneous → Variants).")
        }
    }

    private var warning: String? {
        if let loadError { return loadError }
        if !hasPassword { return "Save the password above to use variants." }
        guard !model.aioStreamsVariant.isEmpty else { return nil }
        guard let selected = variants.first(where: { $0.id == model.aioStreamsVariant }) else {
            return "Your configuration has no variant \"\(model.aioStreamsVariant)\"."
        }
        return selected.enabled ? nil : "This variant is disabled in AIOStreams."
    }

    private func create() {
        isCreating = true
        createError = nil
        Task {
            do {
                try await model.createUnfilteredAIOStreamsVariant()
                await load()
            } catch {
                createError = error.localizedDescription
            }
            isCreating = false
        }
    }

    private func load() async {
        guard hasPassword else {
            variants = []
            loadError = nil
            return
        }
        do {
            variants = try await model.aioStreamsVariants()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
