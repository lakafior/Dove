import DoveKit
import SwiftUI

/// The player Play uses on this device, a custom URL template, and Kodi.
struct PlaybackSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var playback = model.playback
        Form {
            Section {
                ForEach(ExternalPlayer.allCases) { player in
                    Button {
                        playback.player = player
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(player.displayName)
                                if let note = note(for: player) {
                                    Text(note).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if playback.player == player {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    // Rows read as a list to pick from, not as blue buttons.
                    .tint(.primary)
                }
            } header: {
                Text("Play in")
            } footer: {
                Text("Play buttons use this player on this device. Long-press a source or file for \"Play in…\" with the others. Only Infuse and Kodi take a whole season at once; the others get the first episode.")
            }

            Section {
                TextField("myplayer://x-callback-url/play?url={encodedUrl}", text: $playback.customTemplate, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout.monospaced())
            } header: {
                Text("Custom player")
            } footer: {
                Text("For a player not listed, or one whose link format changed. {encodedUrl} is the link encoded for a query, {url} the link as it is, {filename} the file name.")
            }

            Section {
                NavigationLink {
                    KodiSettingsView()
                } label: {
                    LabeledContent("Kodi", value: playback.kodi.map { $0.host } ?? "Not set up")
                }
            }
        }
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func note(for player: ExternalPlayer) -> String? {
        switch player {
        case .kodi: model.playback.kodi == nil ? "Not set up" : nil
        case .custom: model.playback.isUsable(.custom) ? nil : "Needs a template below"
        default: model.playback.isUsable(player) ? nil : "Not installed"
        }
    }
}

/// Kodi's web server: address, port and login, tested before they are kept.
private struct KodiSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var host = ""
    @State private var port = String(KodiServer.defaultPort)
    @State private var username = "kodi"
    @State private var password = ""
    @State private var status: String?
    @State private var isSaving = false

    var body: some View {
        Form {
            Section {
                TextField("192.168.1.20 or kodi.local", text: $host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
            } header: {
                Text("Address")
            } footer: {
                Text("In Kodi: Settings › Services › Control › Allow remote control via HTTP. The port is shown there (8080 by default).")
            }
            Section("Login") {
                TextField("User name", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
            }
            Section {
                Button(action: save) {
                    HStack {
                        Text("Save and test")
                        if isSaving { Spacer(); ProgressView() }
                    }
                }
                .disabled(isSaving || host.trimmingCharacters(in: .whitespaces).isEmpty)
                if let status { Text(status).font(.footnote) }
            }
            if model.playback.kodi != nil {
                Section {
                    Button("Remove Kodi", role: .destructive) {
                        Task {
                            try? await model.playback.saveKodi(nil)
                            host = ""
                            password = ""
                            status = nil
                        }
                    }
                }
            }
        }
        .navigationTitle("Kodi")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        guard let kodi = model.playback.kodi else { return }
        host = kodi.host
        port = String(kodi.port)
        username = kodi.username
        password = kodi.password
    }

    private func save() {
        isSaving = true
        status = nil
        let server = KodiServer(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: Int(port) ?? KodiServer.defaultPort,
            username: username.trimmingCharacters(in: .whitespaces),
            password: password
        )
        Task {
            do {
                try await model.playback.saveKodi(server)
                status = "✅ Kodi answered."
            } catch {
                status = "❌ \(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}
