import DoveKit
import SwiftUI

/// Where downloads of each kind go by default (a long press on Download picks another place), and whether this
/// device can use iCloud Drive › Dove.
struct DownloadSettingsView: View {
    @Environment(AppModel.self) private var model

    private var kinds: [ContentKind] {
        [.books, .audiobooks, .music, .video, .software, .other] + (model.showAdult ? [.adult] : [])
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("iCloud Drive", value: iCloudState)
            } footer: {
                Text("Files kept in iCloud Drive › Dove reach your iPhone, iPad and Mac, open in Files and Apple Books, and show in the Library as their own place. Without iCloud Drive, every download stays on this iPhone.")
            }
            Section {
                ForEach(kinds, id: \.self) { kind in
                    Picker(selection: binding(for: kind)) {
                        ForEach(model.places, id: \.self) { place in
                            Text(place.displayName).tag(place)
                        }
                    } label: {
                        Label(kind.displayName, systemImage: kind.symbol)
                    }
                    .disabled(model.places.count < 2)
                }
            } header: {
                Text("Download to")
            } footer: {
                Text("Downloads from plugins use these; a long press on Download picks another place for one file. Offcloud, TorBox and Premiumize fetch the file into their cloud (Real-Debrid, AllDebrid and Debrid-Link only take hosters they list).")
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var iCloudState: String {
        if model.iCloudFolder != nil { return "On" }
        return model.iCloudChecked ? "Not available" : "Checking…"
    }

    private func binding(for kind: ContentKind) -> Binding<FilePlace> {
        Binding(
            get: { model.place(for: kind) },
            set: { model.downloadDestinations.set($0, for: kind) }
        )
    }
}
