import DoveKit
import SwiftUI

/// Where book and audiobook covers and titles come from: the built-in sources, the two that need the user's
/// key, and metadata providers the user adds by URL (Audiobookshelf's format).
struct BookMetadataSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var googleKey = ""
    @State private var hardcoverToken = ""
    @State private var googleStatus: String?
    @State private var hardcoverStatus: String?
    @State private var saving: Set<String> = []
    @State private var providers: [BookProvider] = []
    @State private var editing: BookProvider?
    @State private var addingProvider = false
    @State private var providerError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Open Library", value: "Free")
                LabeledContent("Apple Books", value: "Free")
                LabeledContent("Google Books", value: model.googleBooksKey.isEmpty ? "Needs a key" : "Key set")
                LabeledContent("Hardcover", value: model.hardcoverToken.isEmpty ? "Needs a token" : "Token set")
            } header: {
                Text("Sources")
            } footer: {
                Text("Searched at once for Books and Audiobooks; library covers ask them one by one.")
            }

            Section {
                ForEach(providers) { provider in
                    Button {
                        editing = provider
                    } label: {
                        LabeledContent {
                            Text(provider.enabled ? "On" : "Off")
                        } label: {
                            Text(provider.name).foregroundStyle(.primary)
                            Text(provider.url.host() ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = Set(offsets.map { providers[$0].id })
                    do {
                        try model.removeBookProviders(ids)
                        providers = model.bookProviders
                    } catch {
                        providerError = error.localizedDescription
                    }
                }
                Button("Add provider", systemImage: "plus") { addingProvider = true }
                if let providerError { Text(providerError).font(.footnote).foregroundStyle(.red) }
            } header: {
                Text("Metadata providers")
            } footer: {
                Text("Any Audiobookshelf custom metadata provider: paste its address (and its key, if it has one). The community runs providers for stores and catalogues without an official API. Asked first, before the sources above.")
            }

            keySection(
                title: "Google Books",
                placeholder: "API key",
                value: $googleKey,
                status: googleStatus,
                footer: "Free: Google Cloud Console › APIs & Services › enable Books API › Credentials › API key. Without a key Google's shared quota is nearly always used up.",
                save: saveGoogle
            )
            keySection(
                title: "Hardcover",
                placeholder: "API token",
                value: $hardcoverToken,
                status: hardcoverStatus,
                footer: "Free: hardcover.app › Settings › API. Paste the token with or without \u{201C}Bearer\u{201D}. Tokens expire after a year.",
                save: saveHardcover
            )
        }
        .navigationTitle("Book metadata")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            googleKey = model.googleBooksKey
            hardcoverToken = model.hardcoverToken
            providers = model.bookProviders
        }
        .sheet(isPresented: $addingProvider) {
            BookProviderSheet(provider: nil) { providers = model.bookProviders }
        }
        .sheet(item: $editing) { provider in
            BookProviderSheet(provider: provider) { providers = model.bookProviders }
        }
    }

    private func keySection(
        title: String,
        placeholder: String,
        value: Binding<String>,
        status: String?,
        footer: String,
        save: @escaping () -> Void
    ) -> some View {
        Section {
            SecureField(placeholder, text: value)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(save)
            Button(action: save) {
                HStack {
                    Text("Save and test")
                    if saving.contains(title) { Spacer(); ProgressView() }
                }
            }
            .disabled(saving.contains(title))
            if let status { Text(status).font(.footnote) }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }

    private func saveGoogle() {
        run("Google Books", value: googleKey, status: { googleStatus = $0 }) { try await model.saveGoogleBooksKey($0) }
    }

    private func saveHardcover() {
        run("Hardcover", value: hardcoverToken, status: { hardcoverStatus = $0 }) { try await model.saveHardcoverToken($0) }
    }

    private func run(_ name: String, value: String, status: @escaping (String?) -> Void, save: @escaping (String) async throws -> Void) {
        saving.insert(name)
        status(nil)
        Task {
            do {
                try await save(value)
                status(value.isEmpty ? "Removed." : "✅ \(name) works.")
            } catch {
                status("❌ \(error.localizedDescription)")
            }
            saving.remove(name)
        }
    }
}

/// Adds or edits one provider; it is tested with a search before it is kept.
private struct BookProviderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let provider: BookProvider?
    let onSave: () -> Void
    @State private var name = ""
    @State private var address = ""
    @State private var key = ""
    @State private var enabled = true
    @State private var status: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Address", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Key (optional)", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("On", isOn: $enabled)
                } footer: {
                    Text("The address Audiobookshelf would use (Settings › Item metadata utils › Custom metadata providers). Dove asks its /search.")
                }
                if let status {
                    Section { Text(status).font(.footnote) }
                }
            }
            .navigationTitle(provider == nil ? "Add provider" : "Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving { ProgressView() } else { Button("Save", action: save) }
                }
            }
            .onAppear {
                guard let provider else { return }
                name = provider.name
                address = provider.url.absoluteString
                key = provider.authorization ?? ""
                enabled = provider.enabled
            }
        }
    }

    private func save() {
        guard let url = BookProvider.url(from: address) else {
            status = "❌ Enter the provider's http(s) address."
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let updated = BookProvider(
            id: provider?.id ?? UUID().uuidString,
            name: trimmedName.isEmpty ? (url.host() ?? "Provider") : trimmedName,
            url: url,
            authorization: key.isEmpty ? nil : key,
            enabled: enabled
        )
        isSaving = true
        status = nil
        Task {
            do {
                try await model.saveBookProvider(updated)
                onSave()
                dismiss()
            } catch {
                status = "❌ \(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}
