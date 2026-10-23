import AppIntents
import DoveAppCore
import DoveKit

/// Opens Dove with what the clipboard holds (Shortcuts, Spotlight actions): the File menu's Add from Clipboard. The
/// iPhone's one lives in `App/Activity` (it also compiles into the widgets).
struct AddFromClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Add from Clipboard"
    static let description = IntentDescription("Opens Dove with the magnets and links on the clipboard, ready to add.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let model = AppModel.current, let router = MacRouter.current else { throw DoveIntentError.notRunning }
        MacSourceIntake.addFromClipboard(using: model, router: router)
        return .result()
    }
}
