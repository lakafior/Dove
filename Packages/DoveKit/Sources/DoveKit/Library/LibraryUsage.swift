import Foundation

/// How much the library holds, for the line under Library's title: items and their total size, over whatever the
/// filters leave. From the library list Dove already has; it costs no calls of its own.
public struct LibraryUsage: Sendable, Equatable {
    public var items: Int
    /// Items listed without a size (Offcloud) add nothing.
    public var bytes: Int64

    public init(_ items: [ShelfItem]) {
        self.items = items.count
        bytes = items.reduce(0) { $0 + (Self.size(of: $1.item) ?? 0) }
    }

    /// The service's size, else the sum of the files it listed with a size.
    static func size(of item: LibraryItem) -> Int64? {
        if let size = item.size, size > 0 { return size }
        let sizes = item.files.compactMap(\.size).filter { $0 > 0 }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }
}
