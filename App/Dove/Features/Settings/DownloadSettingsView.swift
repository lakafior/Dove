import DoveAppCore
import DoveKit
import SwiftUI

/// Settings › Save to: where downloads of each kind go by default (a long press on Download picks another place).
struct DownloadSettingsView: View {
    @Environment(AppModel.self) private var model

    private var kinds: [ContentKind] {
        [.books, .audiobooks, .music, .video, .games, .software, .other] + (model.showAdult ? [.adult] : [])
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                ForEach(kinds, id: \.self) { kind in
                    Picker(selection: $model[destinationFor: kind]) {
                        ForEach(model.places(for: kind), id: \.self) { place in
                            Text(place.displayName).tag(place)
                        }
                    } label: {
                        Label(kind.displayName, systemImage: kind.symbol)
                    }
                    .disabled(model.places(for: kind).count < 2)
                }
            } footer: {
                Text("Downloads from plugins use these; a long press on Download picks another place for one file. Offcloud, TorBox and Premiumize fetch the file into their cloud (Real-Debrid, AllDebrid and Debrid-Link only take hosters they list). Calibre takes books: Dove downloads the file and adds it with the book's details. iCloud Drive: \(model.iCloudState).")
            }
        }
        .navigationTitle("Save to")
        .navigationBarTitleDisplayMode(.inline)
    }
}
