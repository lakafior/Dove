import DoveKit
import FileProvider
import UniformTypeIdentifiers

/// A `LibraryNode` as Files sees it. Immutable, so sharing it across threads is safe.
final class FileProviderItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    let node: LibraryNode

    init(_ node: LibraryNode) {
        self.node = node
    }

    var itemIdentifier: NSFileProviderItemIdentifier { node.id.providerIdentifier }
    var parentItemIdentifier: NSFileProviderItemIdentifier { node.parent.providerIdentifier }
    var filename: String { node.name }

    var contentType: UTType {
        node.isFolder ? .folder : UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .data
    }

    var documentSize: NSNumber? { node.isFolder ? nil : node.size.map { NSNumber(value: $0) } }
    var creationDate: Date? { node.date }
    var contentModificationDate: Date? { node.date }

    /// Everything below the root is writable on disk, though Dove never changes a service through it
    /// (`modifyItem` refuses edits): read-only items get a lock in Files, cannot be materialized on the
    /// Simulator (EPERM while fileproviderd sets their metadata), and a read-only parent blocks deleting its
    /// children. Service folders take dropped `.torrent`/`.nzb` files (`createItem`). Deleting an item folder
    /// deletes the item from its service; its contents are marked deletable only so Files allows that.
    var capabilities: NSFileProviderItemCapabilities {
        var capabilities: NSFileProviderItemCapabilities = [.allowsReading]
        if node.id != .root { capabilities.insert(.allowsWriting) }
        if node.isDeletable { capabilities.insert(.allowsDeleting) }
        return capabilities
    }

    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data(node.contentVersion.utf8), metadataVersion: Data(node.metadataVersion.utf8))
    }
}

extension LibraryNodeID {
    var providerIdentifier: NSFileProviderItemIdentifier {
        self == .root ? .rootContainer : NSFileProviderItemIdentifier(rawValue)
    }

    /// Nil for the working set and the trash, which are not places in the library.
    init?(_ identifier: NSFileProviderItemIdentifier) {
        if identifier == .rootContainer {
            self = .root
        } else if identifier == .workingSet || identifier == .trashContainer {
            return nil
        } else {
            self.init(rawValue: identifier.rawValue)
        }
    }
}
