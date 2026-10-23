import SwiftUI

/// How a level of the Library shows what it holds: cards (Icons) or a table (List). One setting for the whole Library,
/// remembered across launches (`macLibraryViewMode`); View › as Icons and View › as List change it too.
enum LibraryViewMode: String, CaseIterable, Hashable {
    case icons, list

    /// The `@AppStorage` key every Library level reads.
    static let storageKey = "macLibraryViewMode"

    var title: String { self == .icons ? "Icons" : "List" }
    var symbol: String { self == .icons ? "square.grid.2x2" : "list.bullet" }
}

/// The segmented Icons | List control for a page's toolbar.
struct ViewModePicker: View {
    @Binding var mode: LibraryViewMode

    var body: some View {
        Picker("View", selection: $mode) {
            ForEach(LibraryViewMode.allCases, id: \.self) { mode in
                Label(mode.title, systemImage: mode.symbol).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .help("Show as icons or as a list (⌥⌘1, ⌥⌘2)")
    }
}
