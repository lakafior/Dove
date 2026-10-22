import Foundation

/// SwiftUI's list editing helpers (`onDelete`/`onMove` hand over offsets), without importing SwiftUI here.
extension Array {
    mutating func remove(atOffsets offsets: IndexSet) {
        for index in offsets.reversed() { remove(at: index) }
    }

    /// Moves the elements at `source` to just before the element that was at `destination`, as SwiftUI does.
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { self[$0] }
        let before = source.count { $0 < destination }
        remove(atOffsets: source)
        insert(contentsOf: moving, at: destination - before)
    }
}
