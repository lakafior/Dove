import AppIntents
import DoveKit
import SwiftUI
import WidgetKit

// Home and Lock Screen widgets. They only draw `WidgetSnapshot`, which the app writes to the App Group after each
// refresh and reloads the timelines when something changed; the hourly reload only redraws the snapshot's age.

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: .now, snapshot: .preview) }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snapshot: context.isPreview ? .preview : Self.load() ?? .preview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        completion(Timeline(entries: [SnapshotEntry(date: .now, snapshot: Self.load())], policy: .after(.now + 3600)))
    }

    static func load() -> WidgetSnapshot? {
        SharedConfiguration.appGroupContainer.flatMap(WidgetSnapshot.load)
    }
}

/// An image the app copied next to the snapshot.
func snapshotImage(_ name: String?) -> UIImage? {
    guard let name, let container = SharedConfiguration.appGroupContainer else { return nil }
    return UIImage(contentsOfFile: WidgetSnapshot.imagesURL(in: container).appending(path: name).path())
}

private struct EmptyWidget: View {
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "bird").font(.title2).foregroundStyle(.tint)
            Text(text).font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }
}

extension WidgetSnapshot.Service.Light {
    var color: Color {
        switch self {
        case .good: .green
        case .warning: .orange
        case .failed: .red
        case .unknown: .gray
        }
    }
}

extension Int64 {
    var bytesText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

// MARK: - Services

struct ServicesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DoveServices", provider: SnapshotProvider()) { entry in
            ServicesView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "dove://settings"))
        }
        .configurationDisplayName("Services")
        .description("Your debrid and Usenet services: online or not, and days of premium left.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryRectangular, .accessoryCircular])
    }
}

private struct ServicesView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot?

    var body: some View {
        if let snapshot, !snapshot.services.isEmpty {
            switch family {
            case .accessoryInline:
                if let soonest = snapshot.soonestExpiry {
                    Text("\(soonest.backend.abbreviation) \(soonest.daysLeft!) d")
                } else {
                    Text("Dove: \(snapshot.services.count) services")
                }
            case .accessoryCircular:
                if let soonest = snapshot.soonestExpiry, let days = soonest.daysLeft {
                    Gauge(value: Double(min(days, 30)), in: 0...30) {
                        Text(soonest.backend.abbreviation)
                    } currentValueLabel: {
                        Text("\(days)")
                    }
                    .gaugeStyle(.accessoryCircular)
                } else {
                    Image(systemName: "checkmark.circle")
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(snapshot.services.sorted { ($0.daysLeft ?? .max) < ($1.daysLeft ?? .max) }.prefix(3)) { service in
                        Text("\(service.backend.abbreviation)  \(service.daysLeft.map { "\($0) d" } ?? (service.status ?? "—"))")
                            .font(.caption)
                    }
                }
            default:
                let rows = family == .systemSmall ? 5 : 8
                VStack(alignment: .leading, spacing: 4) {
                    Text("Services").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    let columns = family == .systemMedium ? [GridItem(.flexible()), GridItem(.flexible())] : [GridItem(.flexible())]
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                        ForEach(snapshot.services.prefix(rows)) { service in
                            HStack(spacing: 6) {
                                Circle().fill(service.light.color).frame(width: 7, height: 7)
                                Text(service.backend.abbreviation).font(.caption.weight(.bold)).foregroundStyle(service.backend.tint)
                                Spacer(minLength: 2)
                                Text(service.daysLeft.map { "\($0) d" } ?? service.status ?? "")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(service.light == .good ? .secondary : service.light.color)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        } else {
            EmptyWidget(text: "Open Dove to see your services.")
        }
    }
}

// MARK: - Library

struct LibraryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DoveLibrary", provider: SnapshotProvider()) { entry in
            LibraryWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "dove://library"))
        }
        .configurationDisplayName("Library")
        .description("How much each service holds, and what is still being fetched.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct LibraryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot?

    var body: some View {
        if let snapshot, !snapshot.services.isEmpty {
            let services = snapshot.services.filter { $0.items > 0 }.sorted { $0.bytes > $1.bytes }
            let largest = max(services.first?.bytes ?? 1, 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(snapshot.totalItems) items").font(.headline)
                    Text(snapshot.totalBytes.bytesText).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if snapshot.totalActive > 0 {
                        Label("\(snapshot.totalActive)", systemImage: "arrow.down.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                ForEach(services.prefix(family == .systemLarge ? 8 : 3)) { service in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(service.name).font(.caption.weight(.medium))
                            Spacer()
                            Text("\(service.items) · \(service.bytes.bytesText)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        GeometryReader { proxy in
                            Capsule().fill(service.backend.tint.opacity(0.85))
                                .frame(width: max(4, proxy.size.width * Double(service.bytes) / Double(largest)))
                        }
                        .frame(height: 5)
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            EmptyWidget(text: "Open Dove to see your library.")
        }
    }
}

// MARK: - Watchlist

struct WatchlistWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DoveWatchlist", provider: SnapshotProvider()) { entry in
            WatchlistWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Watchlist")
        .description("New episodes and release dates of what you saved.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct WatchlistWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot?

    var body: some View {
        if let lines = snapshot?.watchlist, let first = lines.first {
            if family == .systemSmall {
                VStack(alignment: .leading, spacing: 4) {
                    poster(first.image, width: 44)
                    Spacer(minLength: 0)
                    Text(first.title).font(.caption.weight(.semibold)).lineLimit(2)
                    if let status = first.status {
                        Text(status).font(.caption2).foregroundStyle(first.isNews ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .widgetURL(first.link)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Watchlist").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(lines.prefix(3)) { line in
                        Link(destination: line.link ?? URL(string: "dove://watchlist")!) {
                            HStack(spacing: 8) {
                                poster(line.image, width: 22)
                                Text(line.title).font(.caption.weight(.medium)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(line.status ?? "").font(.caption2)
                                    .foregroundStyle(line.isNews ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        } else {
            EmptyWidget(text: "Save movies and series with the bookmark in Dove.")
                .widgetURL(URL(string: "dove://watchlist"))
        }
    }

    private func poster(_ name: String?, width: CGFloat) -> some View {
        Group {
            if let image = snapshotImage(name) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Listening

struct ListeningWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DoveListening", provider: SnapshotProvider()) { entry in
            ListeningWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "dove://listening"))
        }
        .configurationDisplayName("Listening")
        .description("The audiobook you are listening to, with a Play button.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct ListeningWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot?

    var body: some View {
        if let book = snapshot?.listening {
            HStack(alignment: .top, spacing: 12) {
                if family == .systemMedium { cover(book, side: 110) }
                VStack(alignment: .leading, spacing: 4) {
                    if family == .systemSmall { cover(book, side: 54) }
                    Text(book.title).font(.caption.weight(.semibold)).lineLimit(2)
                    if let author = book.author { Text(author).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 0)
                    if let progress = book.progress { ProgressView(value: progress) }
                    Button(intent: ContinueAudiobookIntent()) {
                        Label(book.isPlaying ? "Playing" : "Play", systemImage: book.isPlaying ? "waveform" : "play.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        } else {
            EmptyWidget(text: "Start an audiobook in Dove to continue it here.")
        }
    }

    private func cover(_ book: WidgetSnapshot.Listening, side: CGFloat) -> some View {
        Group {
            if let image = snapshotImage(book.image) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "headphones").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Preview data

extension WidgetSnapshot {
    /// What the widget gallery shows before Dove has written a snapshot.
    static let preview = WidgetSnapshot(
        services: [
            .init(backend: .realDebrid, light: .good, daysLeft: 56, items: 42, bytes: 812_000_000_000),
            .init(backend: .torBox, light: .good, daysLeft: 114, items: 31, bytes: 640_000_000_000, active: 2),
            .init(backend: .premiumize, light: .warning, daysLeft: 5, items: 9, bytes: 120_000_000_000),
            .init(backend: .nzbdav, light: .good, status: "Connected", items: 18, bytes: 300_000_000_000),
        ],
        watchlist: [
            .init(id: "1", title: "Severance", status: "New S03E04", isNews: true),
            .init(id: "2", title: "Dune: Part Three", status: "Theaters 18 Dec"),
        ],
        listening: .init(title: "Project Hail Mary", author: "Andy Weir", progress: 0.42)
    )
}
