import DoveAppCore
import DoveKit
import SwiftUI

/// One addon: what it is and what Dove uses it for. AIOStreams gets its Search API password and variant here.
struct AddonDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entryID: String

    private var entry: AppModel.AddonEntry? {
        model.addonEntries.first { $0.id == entryID }
    }

    var body: some View {
        Form {
            if let entry {
                Section {
                    LabeledContent("Name", value: entry.addon?.manifest.name ?? "—")
                    if let version = entry.addon?.manifest.version {
                        LabeledContent("Version", value: version)
                    }
                    LabeledContent("Host", value: entry.url.host() ?? "—")
                    if let manifest = entry.addon?.manifest {
                        LabeledContent("Used for", value: roles(of: manifest))
                    } else if let error = entry.error {
                        Text(error).foregroundStyle(.red)
                    }
                } footer: {
                    if let description = entry.addon?.manifest.description {
                        Text(description)
                    }
                }

                if entry.isAIOStreams {
                    Section {
                        AIOStreamsPasswordRow()
                    } header: {
                        Text("Search API")
                    } footer: {
                        Text("The password of this AIOStreams configuration. With it Dove gets info hashes, cache status per service and season packs, so sources can go to your library, not only play.")
                    }
                    AIOStreamsVariantSection()
                }

                Section {
                    Button("Remove addon", role: .destructive) {
                        if let index = model.addonEntries.firstIndex(where: { $0.id == entryID }) {
                            model.removeAddons(at: [index])
                        }
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(entry?.addon?.manifest.name ?? "Addon")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func roles(of manifest: StremioManifest) -> String {
        var roles: [String] = []
        if manifest.canSearch { roles.append("Search") }
        if manifest.provides("meta") { roles.append("Metadata") }
        if manifest.provides("stream") { roles.append("Streams") }
        return roles.isEmpty ? "Nothing" : roles.joined(separator: ", ")
    }
}
