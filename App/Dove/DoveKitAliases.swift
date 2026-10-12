import DoveKit

/// SwiftUI also declares `LibraryItem` (Xcode library items), so files importing both modules
/// get an ambiguous lookup. A declaration in this module wins over both imports.
typealias LibraryItem = DoveKit.LibraryItem
