import Foundation

/// Where torrents from private trackers go (Settings › Order and fallback › Private trackers). Only services that keep
/// seeding may take them: Debrid-Link always, TorBox on a plan that seeds. Stored in the Keychain
/// (`CredentialKey.privateTrackers`) so the share extension routes the same way.
public enum PrivateTrackerTarget: String, Sendable, CaseIterable, Identifiable {
    /// Debrid-Link when it is set up, otherwise TorBox when its plan seeds.
    case automatic
    case debridLink
    case torBox
    /// Either, in the debrid priority order.
    case both

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .automatic: "Automatic"
        case .debridLink: "Debrid-Link"
        case .torBox: "TorBox"
        case .both: "Both"
        }
    }

    /// Services that take private trackers' torrents, given which of the two can (`debridLink`: has a key;
    /// `torBox`: has a key and a plan that seeds). A choice that is not possible right now (key removed, plan
    /// changed) falls back to automatic rather than refusing everything.
    public func services(debridLink: Bool, torBox: Bool) -> Set<BackendID> {
        switch self {
        case .debridLink where debridLink: [.debridLink]
        case .torBox where torBox: [.torBox]
        case .both: Set([debridLink ? BackendID.debridLink : nil, torBox ? .torBox : nil].compactMap { $0 })
        default: debridLink ? [.debridLink] : torBox ? [.torBox] : []
        }
    }
}
