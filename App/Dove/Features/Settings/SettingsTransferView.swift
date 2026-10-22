import DoveAppCore
import DoveKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Export & import: Dove's settings as a JSON file (`SettingsBackup`), for installs iCloud Keychain
/// does not reach (another team's signature, the Simulator). With or without keys and passwords, like AIOStreams.
struct SettingsTransferView: View {
    @Environment(AppModel.self) private var model
    @State private var includeSecrets = false
    @State private var confirmSecrets = false
    @State private var exportFile: SettingsFile?
    @State private var isImporting = false
    @State private var pending: SettingsBackup?
    @State private var isApplying = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle("Include keys and passwords", isOn: $includeSecrets)
                Button("Export…", systemImage: "square.and.arrow.up") {
                    if includeSecrets { confirmSecrets = true } else { export() }
                }
            } header: {
                Text("Export")
            } footer: {
                Text(includeSecrets
                    ? "The file holds every API key, password and addon link in plain text. Anyone with it can use your accounts: keep it private and delete it once imported."
                    : "Services, priorities, filters, indexers and Kodi without their keys and passwords; addon links are left out (they carry tokens). Import fills in what the other device already has.")
            }

            Section {
                Button("Import from file…", systemImage: "square.and.arrow.down") { isImporting = true }
                    .disabled(isApplying)
                if isApplying { ProgressView("Loading your services…") }
                if let message { Text(message).font(.footnote) }
            } header: {
                Text("Import")
            } footer: {
                Text("Only what the file holds is replaced; everything else on this device stays.")
            }
        }
        .navigationTitle("Export & import")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Export keys and passwords?", isPresented: $confirmSecrets) {
            Button("Export", role: .destructive) { export() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file will hold every key and password in plain text.")
        }
        .fileExporter(
            isPresented: Binding(get: { exportFile != nil }, set: { if !$0 { exportFile = nil } }),
            document: exportFile,
            contentType: .json,
            defaultFilename: exportFile?.name
        ) { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): read(url)
            case .failure(let error): message = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Import these settings?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { backup in
            Button("Import \(backup.values.count) settings") { apply(backup) }
            Button("Cancel", role: .cancel) {}
        } message: { backup in
            Text("Exported \(backup.exportedAt.formatted(date: .abbreviated, time: .shortened)), \(backup.includesSecrets ? "with" : "without") keys and passwords. They replace this device's values for the same settings.")
        }
    }

    private func export() {
        do {
            let backup = model.exportSettings(includeSecrets: includeSecrets)
            exportFile = SettingsFile(data: try backup.encoded(), name: backup.fileName)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func read(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            pending = try SettingsBackup.decode(try Data(contentsOf: url))
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func apply(_ backup: SettingsBackup) {
        isApplying = true
        message = nil
        Task {
            defer { isApplying = false }
            do {
                let summary = try await model.importSettings(backup)
                var text = "Imported \(summary.applied.count) settings."
                if !summary.indexersNeedingKeys.isEmpty {
                    text += " Turned off until you add their API keys: \(summary.indexersNeedingKeys.joined(separator: ", "))."
                }
                message = text
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

/// The export as a document for `fileExporter`.
struct SettingsFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data
    var name: String

    init(data: Data, name: String) {
        self.data = data
        self.name = name
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        name = configuration.file.filename ?? "Dove settings.json"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
