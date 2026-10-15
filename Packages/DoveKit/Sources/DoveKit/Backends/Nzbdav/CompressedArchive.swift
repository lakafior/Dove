import Foundation

/// nzbdav and InfiniDysk stream archives without unpacking them, so they take only stored ones (RAR `m0`,
/// 7z Copy). A compressed archive fails the job at once, with no way around it on that server; services that
/// download and unpack (TorBox, Premiumize, Offcloud Usenet) take the same NZB.
///
/// The failure is known only from the job's message: an NZB lists file names, not how they were packed, and
/// nzbdav reads that from the first segment. Messages it answers to:
/// - InfiniDysk: "Compressed RAR archives are intentionally unsupported by InfiniDysk: …" (and "Compressed 7z …")
/// - nzbdav: "Only rar files with compression method m0 are supported." and "Only uncompressed 7z files are supported."
public enum CompressedArchive {
    public static func isFailure(_ reason: String) -> Bool {
        let text = reason.lowercased()
        return text.contains("compress") && (text.contains("rar") || text.contains("7z"))
    }

    /// What the user reads instead of the server's long message.
    public static func explanation(on backend: BackendID) -> String {
        "The release is a compressed archive. \(backend.displayName) streams only uncompressed (stored) RAR and 7z archives, so it cannot open it."
    }
}

extension LibraryItem {
    /// A Usenet job that failed because its archive is compressed (see `CompressedArchive`).
    public var failedOnCompressedArchive: Bool {
        if case .failed(let reason) = status { return CompressedArchive.isFailure(reason) }
        return false
    }
}

extension UsenetPlayback {
    /// Play stopped on a compressed archive: the same NZB can go to a service that unpacks it.
    public struct CompressedArchiveError: Error, Sendable, Equatable, LocalizedError {
        public let backend: BackendID
        /// The failed job, for removing it once the NZB went elsewhere.
        public let itemID: LibraryItem.ID

        public var errorDescription: String? { CompressedArchive.explanation(on: backend) }
    }
}
