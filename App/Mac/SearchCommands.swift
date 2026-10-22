import DoveAppCore
import DoveKit
import SwiftUI

/// Edit › Search… (⌘F) and the categories (⌘1…⌘7; Adult only from the field's menu, where it shows when turned on):
/// a category opens the Search page with that category picked.
struct SearchCommands: Commands {
    let router: MacRouter
    @AppStorage("macSearchCategory") private var category: SearchCategory = .media

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Search…") { router.startSearch() }
                .keyboardShortcut("f")
            Menu("Search In") {
                ForEach(Array(SearchCategory.allCases.filter { $0 != .adult }.enumerated()), id: \.element) { index, item in
                    Button(item.displayName) {
                        category = item
                        router.selection = .search
                        router.startSearch()
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
            }
        }
    }
}
