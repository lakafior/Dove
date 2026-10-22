import DoveKit

/// On iOS, MediaPlayer brings UIKit, which brings DeveloperToolsSupport's `LibraryItem` (SwiftUI's Xcode library
/// entry). Dove's wins inside this module.
public typealias LibraryItem = DoveKit.LibraryItem
