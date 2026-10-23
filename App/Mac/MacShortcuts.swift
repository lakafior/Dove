import AppKit
import DoveAppCore
import DoveKit
import SwiftUI

/// What the page in front can do with its selection, published as a focused scene value so the menu bar can offer it
/// with a shortcut (a nil closure leaves the item disabled). The Library, the sources table and Downloads each fill
/// the ones that make sense for them.
struct MacPageCommands {
    /// ⌘D: download the selected releases to this Mac.
    var download: (() -> Void)?
    /// ⌘↩: add the selected releases to the services (Automatic).
    var add: (() -> Void)?
    /// ⌥↩: play the selected release.
    var play: (() -> Void)?
    /// ⇧⌘R: show the selection's files in the Finder.
    var reveal: (() -> Void)?
    /// ⌘⌫: take the selection off the list (Downloads; the files stay).
    var remove: (() -> Void)?
    /// ⌘I: open the selection's page.
    var open: (() -> Void)?
}

private struct MacPageCommandsKey: FocusedValueKey {
    typealias Value = MacPageCommands
}

extension FocusedValues {
    var pageCommands: MacPageCommands? {
        get { self[MacPageCommandsKey.self] }
        set { self[MacPageCommandsKey.self] = newValue }
    }
}

/// The Go, Item and Playback menus: places (⌃⌘1…⌃⌘5 (Downloads is ⌘D), ⌘[ to go back), what the selection can do, the audio player.
/// ⌘1…⌘7 stay with the search categories. Space (pause/resume a download, else play/pause) is a key press on the
/// window, not a menu key, so it never reaches a text field.
struct MacShortcutCommands: Commands {
    let model: AppModel
    let router: MacRouter
    @FocusedValue(\.pageCommands) private var page

    var body: some Commands {
        CommandMenu("Go") {
            Button("Search") { router.select(.search) }
                .keyboardShortcut("1", modifiers: [.control, .command])
            Button("Library") { router.select(.library(nil)) }
                .keyboardShortcut("2", modifiers: [.control, .command])
            Button("Downloads") { router.select(.downloads) }
                .keyboardShortcut("d")
            Button("On Services") { router.select(.onServices) }
                .keyboardShortcut("4", modifiers: [.control, .command])
            Button("Watchlist") { router.select(.watchlist) }
                .keyboardShortcut("5", modifiers: [.control, .command])
            Divider()
            Button("Back") { router.goBack() }
                .keyboardShortcut("[")
        }
        CommandMenu("Item") {
            Button("Open") { page?.open?() }
                .keyboardShortcut("i")
                .disabled(page?.open == nil)
            Button("Add to Services") { page?.add?() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(page?.add == nil)
            Button("Play") { page?.play?() }
                .keyboardShortcut(.return, modifiers: .option)
                .disabled(page?.play == nil)
            Button("Download") { page?.download?() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(page?.download == nil)
            Divider()
            Button("Remove from List") { page?.remove?() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(page?.remove == nil)
            Button("Show in Finder") { page?.reveal?() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(page?.reveal == nil)
        }
        CommandMenu("Playback") {
            let player = model.audiobook
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                .disabled(player.session == nil)
            Button("Next Track") { MacShortcutCommands.next(player) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(player.session == nil)
            Button("Previous Track") { MacShortcutCommands.previous(player) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(player.session == nil)
        }
    }

    /// Music steps by track, an audiobook by chapter.
    static func next(_ player: AudiobookPlayer) {
        if player.session?.isMusic == true { player.nextTrack() } else { player.nextChapter() }
    }

    static func previous(_ player: AudiobookPlayer) {
        if player.session?.isMusic == true { player.previousTrack() } else { player.previousChapter() }
    }
}

/// The page's list or grid takes the keyboard focus. A click on a row selects it, but the table does not always become the first responder (the toolbar's Filter field or
/// the sidebar keeps it): the selection then shows grey, and ⌘A, ⌫ and the arrow keys go elsewhere. Taking the focus when
/// the selection changes makes a click select in blue, as in the Finder.
private struct TakesFocusWhenSelected<ID: Hashable>: ViewModifier {
    let selection: Set<ID>
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onChange(of: selection) { if !selection.isEmpty { focused = true } }
            // The content next to the sidebar is where the keyboard goes: when the page appears, and on any click in
            // it, also on the empty space under the rows.
            .task {
                try? await Task.sleep(for: .milliseconds(150))
                focused = true
            }
            .simultaneousGesture(TapGesture().onEnded { focused = true })
    }
}

extension View {
    func takesFocusWhenSelected<ID: Hashable>(_ selection: Set<ID>) -> some View {
        modifier(TakesFocusWhenSelected(selection: selection))
    }
}
