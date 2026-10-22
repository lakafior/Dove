import AppKit
import DoveKit

/// Downloads on the Dock icon: a badge with how many are running and a bar across the icon for their bytes.
/// Redrawn only when the count changes or the bar moves a percent, since every write of every download reports.
@MainActor
final class DockProgress {
    private let view = DockProgressView()
    private var shown: (count: Int, percent: Int?) = (0, nil)

    func update(_ records: [DownloadRecord]) {
        let running = records.filter { $0.state == .downloading }
        let total = running.compactMap(\.totalBytes).reduce(0, +)
        let written = running.filter { $0.totalBytes != nil }.reduce(0) { $0 + $1.bytesWritten }
        let percent = running.isEmpty || total == 0 ? nil : Int(Double(written) / Double(total) * 100)
        guard running.count != shown.count || percent != shown.percent else { return }
        shown = (running.count, percent)

        let tile = NSApp.dockTile
        tile.badgeLabel = running.isEmpty ? nil : "\(running.count)"
        view.progress = percent.map { Double($0) / 100 }
        if tile.contentView !== view { tile.contentView = view }
        tile.display()
    }
}

/// The app icon with a bar along its bottom; the plain icon when there is no progress to show.
private final class DockProgressView: NSView {
    var progress: Double?

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        guard let progress else { return }
        let inset = bounds.width * 0.14
        let height = bounds.height * 0.09
        let track = NSRect(x: inset, y: bounds.height * 0.1, width: bounds.width - inset * 2, height: height)
        let radius = height / 2
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        var filled = track.insetBy(dx: 2, dy: 2)
        filled.size.width *= max(0.03, min(progress, 1))
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: filled.height / 2, yRadius: filled.height / 2).fill()
    }
}
