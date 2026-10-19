import DoveKit
import SwiftUI

/// Where book and audiobook covers and titles come from: the built-in sources, the two that need the user's
/// key. Plugins with metadata (Settings › Plugins) are asked before them.
struct BookMetadataSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var googleKey = ""
    @State private var hardcoverToken = ""
    @State private var googleStatus: String?
    @State private var hardcoverStatus: String?
    @State private var saving: Set<String> = []

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
                let plugins = model.plugins.calls(.metadata)
                if plugins.isEmpty {
                    Text("None. Plugins can add more sources: Settings › Plugins.").foregroundStyle(.secondary)
                }
                ForEach(plugins, id: \.id) { call in
                    LabeledContent(call.manifest.name, value: call.manifest.categories.map(\.displayName).joined(separator: ", "))
                }
            } header: {
                Text("From plugins")
            } footer: {
                Text("Asked first, before the sources above.")
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
