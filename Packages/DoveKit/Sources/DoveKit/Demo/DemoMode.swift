import Foundation

/// Debug builds launched with `-demo` show made-up, public-domain content instead of the user's services, for
/// screenshots (`scripts/screenshots.sh`). Nothing real is read or written: see `DoveStorage` and `KeychainStore.demo`.
public enum DemoMode {
    public static let argument = "-demo"

    /// True only in Debug builds launched with `-demo` (screenshots, docs/screenshots). Release builds never.
    public static let isActive: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains(argument)
        #else
        false
        #endif
    }()
}

/// Where Dove keeps its files and defaults: the real places, or throwaway ones in demo mode.
public enum DoveStorage {
    private static let demoRoot: URL = {
        let root = FileManager.default.temporaryDirectory.appending(path: "DoveDemo")
        try? FileManager.default.removeItem(at: root)
        return root
    }()

    /// `Application Support/Dove`; in demo mode a throwaway folder under the temporary directory.
    public static let applicationSupport: URL = {
        DemoMode.isActive
            ? demoRoot.appending(path: "Application Support")
            : URL.applicationSupportDirectory.appending(path: "Dove")
    }()

    /// `Caches/Dove`; in demo mode a throwaway folder under the temporary directory.
    public static let caches: URL = {
        DemoMode.isActive
            ? demoRoot.appending(path: "Caches")
            : URL.cachesDirectory.appending(path: "Dove")
    }()

    /// `UserDefaults.standard`; in demo mode the suite `net.smigi.dove.demo`, emptied on first use each launch.
    nonisolated(unsafe) public static let defaults: UserDefaults = {
        guard DemoMode.isActive else { return .standard }
        let defaults = UserDefaults(suiteName: "net.smigi.dove.demo")!
        defaults.removePersistentDomain(forName: "net.smigi.dove.demo")
        return defaults
    }()
}
