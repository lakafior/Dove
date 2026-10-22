import AppIntents
#if !WIDGET_EXTENSION
import DoveAppCore
#endif

/// Plays on the audiobook last listened to, from its saved place, without opening Dove. Compiled into the app and
/// `DoveWidgets` (the Listening widget's Play button); as an `AudioPlaybackIntent` it always runs in the app's
/// process, so the widget's copy never performs.
struct ContinueAudiobookIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Continue Audiobook"
    static let description = IntentDescription("Plays the audiobook you listened to last, from where you left it.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if WIDGET_EXTENSION
        return .result(dialog: "Open Dove to continue.")
        #else
        guard let model = AppModel.current else { throw DoveIntentError.notRunning }
        switch await model.continueAudiobook() {
        case .playing(let name): return .result(dialog: "Playing \(name).")
        case .failed(let message): throw DoveIntentError.failed(message)
        }
        #endif
    }
}
