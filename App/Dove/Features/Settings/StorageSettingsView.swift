import DoveKit
import SwiftUI

/// What Dove keeps on this phone besides downloads (artwork, books opened with Read), and the "Dove" location
/// in the Files app, re-registered when Files shows an error next to it.
struct StorageSettingsView: View {
    @State private var imageBytes: Int64?
    @State private var bookBytes: Int64?
    @State private var filesStatus: SettingsStatus?

    var body: some View {
        Form {
            Section {
                LabeledContent("Posters and covers", value: size(imageBytes))
                Button("Clear artwork", role: .destructive) {
                    Task {
                        await ImageCache.shared.removeAll()
                        DecodedImages.shared.removeAll()
                        imageBytes = await ImageCache.shared.size()
                    }
                }
                .disabled(imageBytes == 0)
            } footer: {
                Text("Kept so the library does not download artwork again on every launch.")
            }

            Section {
                LabeledContent("Books opened with Read", value: size(bookBytes))
                Button("Clear books", role: .destructive) {
                    BookFileCache().removeAll()
                    bookBytes = 0
                }
                .disabled(bookBytes == 0)
            } footer: {
                Text("Kept so a second Read does not download the book again. iOS may clear both when space runs low; Dove then fetches them again as needed. Downloads are in the Downloads tab.")
            }

            Section {
                Button(action: resetFiles) {
                    HStack {
                        Text("Reset Files location")
                        if filesStatus == .testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(filesStatus == .testing)
                if let filesStatus, filesStatus != .testing { SettingsStatusView(status: filesStatus) }
            } header: {
                Text(Self.filesTitle)
            } footer: {
                Text(Self.filesFooter)
            }
        }
        .navigationTitle("Storage and Files")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            bookBytes = BookFileCache().size()
            imageBytes = await ImageCache.shared.size()
        }
    }

    private func size(_ bytes: Int64?) -> String {
        bytes.map { $0.formatted(.byteCount(style: .file)) } ?? "…"
    }

    #if os(iOS)
    private static let filesTitle = "Files app"
    private static let filesDone = "Done. Open Files, tap Dove and turn it on."
    private static let filesFooter = "Your services appear in Files under Locations › Dove. If Files shows an error there, reset it: Files forgets what it knew and lists everything again."
    #else
    private static let filesTitle = "Finder"
    private static let filesDone = "Done. Dove appears again in Finder's sidebar; if it does not, turn it on in System Settings › General › Login Items & Extensions › Added Extensions."
    private static let filesFooter = "Your services appear in Finder's sidebar under Locations › Dove. If Finder shows an error there, reset it: Finder forgets what it knew and lists everything again."
    #endif

    private func resetFiles() {
        filesStatus = .testing
        Task {
            do {
                try await FilesLocation.reset()
                filesStatus = .success(Self.filesDone)
            } catch {
                filesStatus = SettingsStatus(error)
            }
        }
    }
}
