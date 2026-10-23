import AppKit
import DoveAppCore
import DoveKit
import SwiftUI

/// UserDefaults keys of the two Mac-only switches (Settings window, bottom of the sidebar).
enum MacMenuBarSettings {
    static let showExtra = "macShowMenuBarExtra"
    static let keepRunning = "macKeepRunning"

    /// Both default to on: downloads go on after the last window closes, and the menu bar shows that Dove is there.
    static var keepsRunning: Bool {
        UserDefaults.standard.object(forKey: keepRunning) as? Bool ?? true
    }
}

/// The menu bar extra: what Dove is doing while its window is closed. Downloads to this Mac, download-only jobs
/// waiting on a service, what the audio player is playing, Add from Clipboard, and the way back to the window.
struct MacMenuBar: View {
    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router
    @Environment(\.openWindow) private var openWindow

    private var running: [DownloadRecord] { model.downloads.records.filter { $0.state == .downloading } }
    private var waiting: [DownloadJob] {
        model.downloadJobs.jobs.filter { if case .failed = $0.state { false } else { true } }
    }

    var body: some View {
        let player = model.audiobook
        if let entry = player.currentEntry, player.session != nil {
            Text(entry.title)
            if let artist = entry.artist ?? entry.album { Text(artist) }
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                player.togglePlayPause()
            }
            if player.session?.isMusic == true {
                Button("Next Track", systemImage: "forward.fill") { player.nextTrack() }
                Button("Previous Track", systemImage: "backward.fill") { player.previousTrack() }
            } else {
                Button("Back 15 Seconds", systemImage: "gobackward.15") { player.skip(by: -15) }
                Button("Forward 30 Seconds", systemImage: "goforward.30") { player.skip(by: 30) }
            }
            Divider()
        }

        if running.isEmpty && waiting.isEmpty {
            Text("No downloads").foregroundStyle(.secondary)
        } else {
            ForEach(running.prefix(6)) { record in
                Text(line(record))
            }
            if running.count > 6 { Text("and \(running.count - 6) more") }
            ForEach(waiting.prefix(4)) { job in
                Text("\(job.name) · waiting for \(job.backend.displayName)")
            }
        }
        Button("Show Downloads", systemImage: "arrow.down.circle") { open(.downloads) }

        Divider()
        Button("Add from Clipboard", systemImage: "doc.on.clipboard") {
            showWindow()
            MacSourceIntake.addFromClipboard(using: model, router: router)
        }
        Button("Open Dove", systemImage: "bird") { showWindow() }
        Divider()
        Button("Quit Dove") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func line(_ record: DownloadRecord) -> String {
        guard let progress = record.progress else { return record.name }
        return "\(record.name) · \(Int(progress * 100))%"
    }

    private func open(_ destination: AppModel.Destination) {
        showWindow()
        model.show(destination)
    }

    /// Brings the window back, opening one when it was closed.
    private func showWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true || $0.title == "Dove" }),
           !(window is NSPanel) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}

/// The menu bar icon: the bird, filling from the bottom as the running downloads' bytes arrive, green for a few seconds
/// when the last one is done. Idle, it is the plain outline.
struct MacMenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @State private var justFinished = false

    var body: some View {
        let records = model.downloads.records
        let running = records.filter { $0.state == .downloading }
        let total = running.compactMap(\.totalBytes).reduce(0, +)
        let written = running.filter { $0.totalBytes != nil }.reduce(0) { $0 + $1.bytesWritten }
        // A download of unknown size shows the bird a quarter full, so it still looks busy.
        let percent = running.isEmpty ? nil : (total > 0 ? Int(Double(written) / Double(total) * 100) : 25)
        let finished = records.filter { $0.state == .finished }.count
        Image(nsImage: BirdIcon.image(percent: justFinished ? nil : percent, done: justFinished))
            .onChange(of: finished) { old, new in
                guard new > old, running.isEmpty else { return }
                justFinished = true
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    justFinished = false
                }
            }
    }
}

/// The bird drawn as an image for the status item: a template (the menu bar tints it for light and dark) with the lower
/// part solid, or a green one when done. Cached per percent, since the label redraws on every write.
@MainActor
enum BirdIcon {
    private static var cache: [Int: NSImage] = [:]

    static func image(percent: Int?, done: Bool) -> NSImage {
        let key = done ? 101 : (percent.map { min(max($0, 0), 100) } ?? -1)
        if let cached = cache[key] { return cached }
        let image = draw(percent: done ? 100 : percent, done: done)
        cache[key] = image
        return image
    }

    private static func draw(percent: Int?, done: Bool) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let color: NSColor = done ? .systemGreen : .black
        func symbol(_ name: String) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: "Dove")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                    .applying(.init(paletteColors: [color])))
        }
        let image = NSImage(size: size, flipped: false) { _ in
            let outline = symbol(percent == nil ? "bird" : "bird.fill")
            guard let outline else { return false }
            let box = NSRect(x: (size.width - outline.size.width) / 2, y: (size.height - outline.size.height) / 2,
                             width: outline.size.width, height: outline.size.height)
            guard let percent else {
                outline.draw(in: box)
                return true
            }
            // The whole bird faint, then the part that has arrived solid, from the bottom.
            outline.draw(in: box, from: .zero, operation: .sourceOver, fraction: done ? 1 : 0.35)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: box.minX, y: box.minY, width: box.width, height: box.height * Double(percent) / 100)).addClip()
            outline.draw(in: box)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        // Green is a colour of its own; the rest is tinted by the menu bar.
        image.isTemplate = !done
        return image
    }
}

/// The two Mac switches, at the bottom of the Settings sidebar.
struct MacMenuBarToggles: View {
    @AppStorage(MacMenuBarSettings.showExtra) private var showExtra = true
    @AppStorage(MacMenuBarSettings.keepRunning) private var keepRunning = true

    var body: some View {
        Section("Mac") {
            Toggle("Show in Menu Bar", isOn: $showExtra)
            Toggle("Keep Running When the Window Closes", isOn: $keepRunning)
                .help("Downloads and download-only jobs go on. Quit from the menu bar or ⌘Q.")
        }
    }
}
