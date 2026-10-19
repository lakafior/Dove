import DoveKit
import MusicKit
import SwiftUI

/// Where album covers, titles and tracks come from: MusicBrainz always, Apple Music when the user turns it on
/// (MusicKit permission, this device only).
struct MusicMetadataSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @AppStorage(AppleMusicCatalog.preferenceKey) private var appleMusic = false
    @State private var status: String?
    @State private var isChecking = false

    var body: some View {
        Form {
            Section {
                LabeledContent("MusicBrainz", value: "Free")
                Toggle(isOn: Binding(get: { appleMusic && MusicAuthorization.currentStatus == .authorized }, set: setAppleMusic)) {
                    HStack {
                        Text("Apple Music")
                        if isChecking { ProgressView().padding(.leading, 4) }
                    }
                }
                .disabled(isChecking)
                if let status {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
                if MusicAuthorization.currentStatus == .denied {
                    Button("Open iPhone Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("Searched at once for Music. MusicBrainz knows releases, years and track lists, but has no cover for many albums. Apple Music adds covers and albums MusicBrainz lacks, from your account's store. No subscription needed; Dove asks once for access to Apple Music and reads only the catalog, never your library.")
            }

            Section {
                let plugins = model.plugins.calls(.metadata, category: .music).filter { $0.manifest.categories.contains(.music) }
                if plugins.isEmpty {
                    Text("None. Plugins can add more sources: Settings › Plugins.").foregroundStyle(.secondary)
                }
                ForEach(plugins, id: \.id) { call in
                    Text(call.manifest.name)
                }
            } header: {
                Text("From plugins")
            } footer: {
                Text("Asked at the same time as the sources above; the same album from several sources is one row.")
            }
        }
        .navigationTitle("Music metadata")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setAppleMusic(_ on: Bool) {
        guard on else {
            appleMusic = false
            status = nil
            return
        }
        isChecking = true
        status = nil
        Task {
            defer { isChecking = false }
            switch await MusicAuthorization.request() {
            case .authorized:
                do {
                    let found = try await AppleMusicCatalog().albums(matching: "radiohead")
                    appleMusic = true
                    status = found.isEmpty ? "Connected, but a test search found nothing." : nil
                } catch {
                    appleMusic = false
                    status = error.localizedDescription
                }
            case .denied:
                status = "Access to Apple Music is off for Dove. Turn it on in iPhone Settings › Dove › Media & Apple Music."
            case .restricted:
                status = "Apple Music is restricted on this iPhone (Screen Time)."
            default:
                // The Simulator (no Apple Music) answers without asking.
                status = "This device did not ask for Apple Music access. It needs the Music app and an Apple Account."
            }
        }
    }
}
