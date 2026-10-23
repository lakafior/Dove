import FileProvider
import Foundation

/// The "Dove" location in the Files app, served by the `DoveFiles` extension.
enum FilesLocation {
    static var domain: NSFileProviderDomain {
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("library"), displayName: "Dove")
        // Deletes go straight to the service; there is no trash to sync.
        if #available(iOS 18, macOS 15, *) { domain.supportsSyncingTrash = false }
        return domain
    }

    /// Bump to rebuild the location from scratch on the next launch: Files keeps retrying jobs for items it
    /// already knows with their old properties (e.g. read-only files it could not create), and only a removed
    /// domain forgets them. iOS asks the user to turn the location on again afterwards.
    private static let generation = 3
    private static let generationKey = "filesDomainGeneration"

    /// Shows the location while at least one service is configured, and tells the extension to re-read keys.
    static func update(hasServices: Bool) async {
        guard hasServices else {
            try? await NSFileProviderManager.remove(domain)
            return
        }
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: generationKey) != generation {
            try? await NSFileProviderManager.remove(domain)
            defaults.set(generation, forKey: generationKey)
        }
        try? await NSFileProviderManager.add(domain)
        libraryChanged()
    }

    /// Settings › Storage and Files: drops everything Files knows about the location (stuck jobs, old errors) and
    /// registers it again. iOS asks the user to turn it on afterwards. (The system also keeps a default,
    /// non-replicated domain for every extension; it cannot be removed and is harmless.)
    static func reset() async throws {
        try? await NSFileProviderManager.remove(domain)
        try await NSFileProviderManager.add(domain)
        libraryChanged()
    }

    /// After a refresh, add or delete in the app: Files asks the extension what changed.
    static func libraryChanged() {
        NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
    }
}
