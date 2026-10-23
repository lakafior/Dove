import SwiftUI

/// View › as Icons (⌥⌘1) and View › as List (⌥⌘2): the Library's one setting (`LibraryViewMode`). ⌘1…⌘7 are the search
/// categories (`SearchCommands`), so the view modes take Option.
struct ViewModeCommands: Commands {
    @AppStorage(LibraryViewMode.storageKey) private var mode: LibraryViewMode = .icons

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Toggle("as Icons", isOn: Binding(get: { mode == .icons }, set: { if $0 { mode = .icons } }))
                .keyboardShortcut("1", modifiers: [.command, .option])
            Toggle("as List", isOn: Binding(get: { mode == .list }, set: { if $0 { mode = .list } }))
                .keyboardShortcut("2", modifiers: [.command, .option])
        }
    }
}
