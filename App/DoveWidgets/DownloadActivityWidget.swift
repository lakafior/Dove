import ActivityKit
import DoveKit
import SwiftUI
import WidgetKit

@main
struct DoveWidgets: WidgetBundle {
    var body: some Widget {
        ServicesWidget()
        LibraryWidget()
        WatchlistWidget()
        ListeningWidget()
        DownloadActivityWidget()
        if #available(iOS 18.0, *) {
            ContinueListeningControl()
            AddFromClipboardControl()
        }
    }
}

/// Phone downloads on the Lock Screen and in the Dynamic Island (`DownloadAlerts` starts and updates it).
struct DownloadActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            LockScreenView(state: context.state, isStale: context.isStale)
                .padding()
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.isDone ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let fraction = state.fraction, !state.isDone {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.headline.monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.current ?? "Dove").font(.subheadline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressBar(state: state)
                        Text(state.status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: state.isDone ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(.tint)
            } compactTrailing: {
                if let fraction = state.fraction, !state.isDone {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                } else {
                    Text("\(state.isDone ? state.finished : state.active)").font(.caption.monospacedDigit())
                }
            } minimal: {
                Image(systemName: state.isDone ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
    }
}

private struct LockScreenView: View {
    let state: DownloadActivitySummary
    let isStale: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.isDone ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(state.isDone ? "Downloads finished" : state.current ?? "Downloading")
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if let fraction = state.fraction, !state.isDone {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.headline.monospacedDigit())
                    }
                }
                ProgressBar(state: state)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var detail: String {
        var parts = [state.status]
        if let total = state.totalBytes, !state.isDone {
            parts.append("\(ByteCountFormatter.string(fromByteCount: state.bytesWritten, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
        }
        // iOS pauses progress reports while Dove is in the background; the numbers catch up when it is opened.
        if isStale { parts.append("open Dove to update") }
        return parts.joined(separator: " · ")
    }
}

private struct ProgressBar: View {
    let state: DownloadActivitySummary

    var body: some View {
        if state.isDone {
            ProgressView(value: 1)
        } else if let fraction = state.fraction {
            ProgressView(value: fraction)
        } else {
            ProgressView(value: 0).opacity(0.4)
        }
    }
}
