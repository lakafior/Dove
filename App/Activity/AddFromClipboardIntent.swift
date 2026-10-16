import AppIntents

/// Opens Dove's add sheet with what the clipboard holds (Control Center, Shortcuts): the same as the app icon's
/// "Add from Clipboard". Compiled into the app and `DoveWidgets`; it opens the app, which does the work.
struct AddFromClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Add from Clipboard"
    static let description = IntentDescription("Opens Dove with the magnets and links on the clipboard, ready to add.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        QuickActions.perform(QuickActions.addFromClipboard)
        #endif
        return .result()
    }
}
