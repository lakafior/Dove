import DoveKit
import SwiftUI

/// Where book and audiobook covers and titles come from: the free sources this device's region reaches, and
/// the two that need the user's key.
struct BookMetadataSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var googleKey = ""
    @State private var hardcoverToken = ""
    @State private var googleStatus: String?
    @State private var hardcoverStatus: String?
    @State private var saving: Set<String> = []

    private var configuration: BookMetadata.Configuration { model.bookMetadataConfiguration }
    private var metadata: BookMetadata { BookMetadata(configuration: configuration) }

    var body: some View {
        Form {
            Section {
                ForEach(BookSourceRow.rows(for: metadata), id: \.name) { row in
                    LabeledContent(row.name) {
                        Text(row.detail).foregroundStyle(row.isOn ? .secondary : .tertiary)
                    }
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("Searched at once for Books and Audiobooks; library covers ask them one by one. Stores follow this iPhone's region and language. Audible and Storytel are used without an official API and may change.")
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

/// One line per source: on for this device (and which store), or why not.
struct BookSourceRow {
    let name: String
    let detail: String
    let isOn: Bool

    static func rows(for metadata: BookMetadata) -> [BookSourceRow] {
        let sources = metadata.sources(for: .ebook) + metadata.sources(for: .audiobook)
        let apple = sources.compactMap { source -> String? in
            if case .appleBooks(let country) = source { country } else { nil }
        }
        let audible = sources.compactMap { source -> String? in
            if case .audible(let domain) = source { "audible.\(domain)" } else { nil }
        }
        let storytel = sources.lazy.compactMap { source -> String? in
            if case .storytel(let locale) = source { locale } else { nil }
        }.first
        return [
            BookSourceRow(name: "Open Library", detail: "Books", isOn: true),
            BookSourceRow(name: "Apple Books", detail: apple.joined(separator: ", "), isOn: true),
            BookSourceRow(name: "Audible", detail: audible.joined(separator: ", "), isOn: true),
            BookSourceRow(
                name: "Storytel",
                detail: storytel.map { "Market: \($0)" } ?? "Not in this region or language",
                isOn: storytel != nil
            ),
            BookSourceRow(name: "Google Books", detail: sources.contains(.googleBooks) ? "Key set" : "Needs a key", isOn: sources.contains(.googleBooks)),
            BookSourceRow(name: "Hardcover", detail: sources.contains(.hardcover) ? "Token set" : "Needs a token", isOn: sources.contains(.hardcover)),
        ]
    }
}
