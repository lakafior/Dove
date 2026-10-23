import DoveAppCore
import DoveKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

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
                            Text(model.placeName(of: place)).tag(place)
                        }
                    } label: {
                        Label(kind.displayName, systemImage: kind.symbol)
                    }
                    .disabled(model.places(for: kind).count < 2)
                }
            } footer: {
                Text("Downloads from plugins use these; a long press on Download picks another place for one file. Offcloud, TorBox and Premiumize fetch the file into their cloud (Real-Debrid, AllDebrid and Debrid-Link only take hosters they list). Calibre takes books: Dove downloads the file and adds it with the book's details. iCloud Drive: \(model.iCloudState).")
            }
            #if os(macOS)
            foldersSection
            #endif
        }
        .navigationTitle("Save to")
        .navigationBarTitleDisplayMode(.inline)
    }

    #if os(macOS)
    /// Folders on this Mac (a NAS share, an external disk, a Plex or Jellyfin library) that any kind above can save to.
    /// Dove keeps access through a security-scoped bookmark, since the app is sandboxed.
    private var foldersSection: some View {
        Section {
            ForEach(model.folderPlaces) { folder in
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(folder.name)
                            Text(model.pickedFolders.resolve(folder.id)?.path ?? "Not reachable: is the disk connected?")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } icon: {
                        Image(systemName: "externaldrive")
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { model.removeFolderPlace(folder.id) }
                        .buttonStyle(.borderless)
                }
            }
            Button("Add Folder…", systemImage: "plus") { addFolder() }
        } header: {
            Text("Folders on this Mac")
        } footer: {
            Text("Choose one in the pickers above, for example your movies for Video and your music library for Music. A folder on a disk that is not connected is skipped: the file goes to Downloads instead.")
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder for Dove to save downloads in."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.addFolderPlace(url) } catch { NSAlert(error: error).runModal() }
    }
    #endif
}
