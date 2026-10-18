import DoveKit
import SwiftUI

/// Sites for direct file downloads: their address (it moves) and the user's member key. Dove ships none.
struct DirectDownloadsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var sources: [DirectSource] = []
    @State private var editing: DirectSource?
    @State private var adding = false
    @State private var browsing: DirectSource?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                ForEach(sources) { source in
                    Button {
                        editing = source
                    } label: {
                        LabeledContent {
                            Text(source.enabled ? quotaText(source) : "Off")
                        } label: {
                            Text(source.name).foregroundStyle(.primary)
                            Text([source.url.host() ?? "", source.categories.map(\.displayName).joined(separator: ", ")]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Open", systemImage: "safari") { browsing = source }.tint(.blue)
                    }
                }
                .onDelete { offsets in
                    do {
                        try model.removeDirectSources(Set(offsets.map { sources[$0].id }))
                        sources = model.directSources
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                Button("Add site", systemImage: "plus") { adding = true }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text("A site with a member download API (`/dyn/api/fast_download.json`). Search on its own pages in Dove's browser (\u{201C}Search on\u{201D} under the results of the categories you pick); on a file's page, Download fetches it with your key straight to Downloads. Files never go through a service. When the site moves, change its address here.")
            }
        }
        .navigationTitle("Direct downloads")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { sources = model.directSources }
        .sheet(isPresented: $adding) {
            DirectSourceSheet(source: nil) { sources = model.directSources }
        }
        .sheet(item: $editing) { source in
            DirectSourceSheet(source: source) { sources = model.directSources }
        }
        .sheet(item: $browsing) { source in
            DirectBrowserView(start: source.url)
        }
    }

    private func quotaText(_ source: DirectSource) -> String {
        guard let quota = model.directQuotas[source.id], let left = quota.left else { return "On" }
        return quota.perDay.map { "\(left) of \($0) left" } ?? "\(left) left"
    }
}

/// Adds or edits one site; the key is checked (without spending a download) before it is kept.
private struct DirectSourceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: DirectSource?
    let onSave: () -> Void
    @State private var name = ""
    @State private var address = ""
    @State private var key = ""
    @State private var enabled = true
    @State private var categories: Set<SearchCategory> = [.books]
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
                    SecureField("Secret key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("On", isOn: $enabled)
                } footer: {
                    Text("The site's current address (just the domain) and the secret key from your account page.")
                }
                Section {
                    ForEach(offered, id: \.self) { category in
                        Toggle(isOn: binding(for: category)) {
                            Label(category.displayName, systemImage: category.symbolName)
                        }
                    }
                } header: {
                    Text("Search in")
                } footer: {
                    Text("The results of these categories offer \u{201C}Search on\u{201D} this site.")
                }
                if let status {
                    Section { Text(status).font(.footnote) }
                }
            }
            .navigationTitle(source == nil ? "Add site" : "Site")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving { ProgressView() } else { Button("Save", action: save) }
                }
            }
            .onAppear {
                guard let source else { return }
                name = source.name
                address = source.url.absoluteString
                key = source.key
                enabled = source.enabled
                categories = Set(source.categories)
            }
        }
    }

    /// Every search category; Adult only while adult content is shown.
    private var offered: [SearchCategory] {
        SearchCategory.allCases.filter { $0 != .adult || model.showAdult || categories.contains(.adult) }
    }

    private func binding(for category: SearchCategory) -> Binding<Bool> {
        Binding(
            get: { categories.contains(category) },
            set: { on in
                if on { categories.insert(category) } else { categories.remove(category) }
            }
        )
    }

    private func save() {
        guard let url = DirectSource.url(from: address) else {
            status = "❌ Enter the site's http(s) address."
            return
        }
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            status = "❌ Enter your secret key."
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let updated = DirectSource(
            id: source?.id ?? UUID().uuidString,
            name: trimmedName.isEmpty ? (url.host() ?? "Site") : trimmedName,
            url: url,
            key: trimmedKey,
            enabled: enabled,
            categories: SearchCategory.allCases.filter(categories.contains)
        )
        isSaving = true
        status = nil
        Task {
            do {
                try await model.saveDirectSource(updated)
                onSave()
                dismiss()
            } catch {
                status = "❌ \(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}
