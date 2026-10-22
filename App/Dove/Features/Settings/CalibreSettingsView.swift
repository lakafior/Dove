import DoveAppCore
import DoveKit
import SwiftUI

/// Settings › Calibre: the Content server's address at home and away (Tailscale), and an optional login.
struct CalibreSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var url = ""
    @State private var remoteURL = ""
    @State private var user = ""
    @State private var password = ""
    @State private var status: SettingsStatus?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                TextField("http://192.168.1.10:8888", text: $url)
                    .keyboardType(.URL)
                    .textContentType(.URL)
            } header: {
                Text("Address")
            } footer: {
                Text("Calibre › Preferences › Sharing over the net: start the server and use the Mac's address and port, e.g. http://mini.local:8888 (a .local name answers only on the same Wi-Fi).")
            }
            Section {
                TextField("http://100.94.236.49:8888", text: $remoteURL)
                    .keyboardType(.URL)
                    .textContentType(.URL)
            } header: {
                Text("Away from home (optional)")
            } footer: {
                Text("The same server through Tailscale: the Mac's Tailscale IP (100.x.y.z) or its bare name (http://mini:8888 with MagicDNS). iOS allows plain http only to IP addresses, bare names and .local names; a full name like mini.tailnet.ts.net needs https (tailscale serve). Dove tries the home address first and switches when it does not answer.")
            }
            Section {
                TextField("User", text: $user)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
            } header: {
                Text("Login (optional)")
            } footer: {
                Text("Needed when the server asks for a username and password. Set its authentication type to basic (Sharing over the net › Advanced). Listing and downloading work without a login; sending books to Calibre needs an account that may write.")
            }
            Section {
                Button(action: saveAndTest) {
                    HStack {
                        Text("Save and test connection")
                        if isTesting { Spacer(); ProgressView() }
                    }
                }
                .disabled(isTesting)
                if let status { SettingsStatusView(status: status) }
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle("Calibre")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        url = (try? model.keychain.get(.calibreURL)) ?? ""
        remoteURL = (try? model.keychain.get(.calibreRemoteURL)) ?? ""
        user = (try? model.keychain.get(.calibreUser)) ?? ""
        password = (try? model.keychain.get(.calibrePassword)) ?? ""
    }

    /// "192.168.1.10:8888" → "http://192.168.1.10:8888"; no trailing slash.
    private static func address(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !text.isEmpty, !text.contains("://") { text = "http://" + text }
        return text
    }

    private func saveAndTest() {
        let home = Self.address(url)
        let away = Self.address(remoteURL)
        do {
            try model.keychain.set(home.isEmpty ? nil : home, for: .calibreURL)
            try model.keychain.set(away.isEmpty ? nil : away, for: .calibreRemoteURL)
            let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
            try model.keychain.set(trimmedUser.isEmpty ? nil : trimmedUser, for: .calibreUser)
            try model.keychain.set(password.isEmpty ? nil : password, for: .calibrePassword)
        } catch {
            status = .failure("Keychain error: \(error)")
            return
        }
        url = home
        remoteURL = away
        model.reloadBackends()
        guard let calibre = model.backend(.calibre) else {
            status = home.isEmpty && away.isEmpty ? .note("Calibre removed.") : .failure("Enter an address like http://192.168.1.10:8888.")
            Task { await model.library.refresh(using: model) }
            return
        }
        status = .testing
        isTesting = true
        Task {
            defer { isTesting = false }
            do {
                try await calibre.validateCredentials()
                status = .success("Connected.")
                await model.library.refresh(using: model)
            } catch {
                status = SettingsStatus(error)
            }
        }
    }
}
