import AVKit
import DoveAppCore
import DoveKit
import SwiftUI

/// Dove's audio player at the bottom of the window, the Mac form of the iPhone's mini player and full player in one
/// bar: cover, names, the scrubber and, for audiobooks, ±15/30 s, chapters, speed and the sleep timer; for music,
/// previous/next track and shuffle. Shown while a session is loaded (`AudiobookPlayer`).
struct MacNowPlayingBar: View {
    @Environment(AppModel.self) private var model
    /// The scrubber's position while the user drags it; the player's own time otherwise.
    @State private var scrubbing: Double?

    private var player: AudiobookPlayer { model.audiobook }

    var body: some View {
        if let session = player.session {
            HStack(spacing: 14) {
                CachedImage(url: player.currentEntry?.cover ?? session.cover) { Rectangle().fill(.quaternary) }
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(.rect(cornerRadius: 5))
                names(session)
                    .frame(width: 220, alignment: .leading)
                controls(session)
                scrubber
                trailingMenus(session)
                AirPlayButton()
                    .frame(width: 24, height: 24)
                    .help("Choose where the audio plays: AirPlay speakers and other outputs")
                Button("Stop", systemImage: "xmark") { player.stop() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Stop and close the player")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func names(_ session: AudiobookPlayer.Session) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(player.currentEntry?.title ?? session.title).font(.callout.weight(.semibold)).lineLimit(1)
            Group {
                if session.isMusic {
                    Text([player.currentEntry?.artist, player.currentEntry?.album].compactMap { $0 }.joined(separator: " · "))
                } else {
                    Text(player.currentChapter?.title ?? session.author ?? "")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if let error = player.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(1).help(error)
            }
        }
    }

    private func controls(_ session: AudiobookPlayer.Session) -> some View {
        HStack(spacing: 10) {
            if session.isMusic {
                Button("Previous Track", systemImage: "backward.fill") { player.previousTrack() }
            } else {
                Button("Back 15 Seconds", systemImage: "gobackward.15") { player.skip(by: -15) }
            }
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                player.togglePlayPause()
            }
            .font(.title2)
            if session.isMusic {
                Button("Next Track", systemImage: "forward.fill") { player.nextTrack() }
            } else {
                Button("Forward 30 Seconds", systemImage: "goforward.30") { player.skip(by: 30) }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .overlay {
            if player.isLoading { ProgressView().controlSize(.small).offset(y: 22) }
        }
    }

    private var scrubber: some View {
        let duration = max(player.duration ?? 0, 1)
        let value = scrubbing ?? player.elapsed
        return HStack(spacing: 8) {
            Text(Self.time(value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Slider(value: Binding(get: { min(value, duration) }, set: { scrubbing = $0 }), in: 0...duration) { editing in
                if !editing, let scrubbing {
                    player.seek(to: scrubbing)
                    self.scrubbing = nil
                }
            }
            .disabled(player.duration == nil)
            Text(player.duration.map(Self.time) ?? "–:––").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(minWidth: 200)
    }

    @ViewBuilder
    private func trailingMenus(_ session: AudiobookPlayer.Session) -> some View {
        if session.isMusic {
            Toggle("Shuffle", systemImage: "shuffle", isOn: Binding(get: { player.isShuffled }, set: { player.setShuffle($0) }))
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
            Menu("Queue", systemImage: "list.bullet") {
                ForEach(Array(session.queue.enumerated()), id: \.element.id) { index, entry in
                    Button {
                        player.playEntry(at: index)
                    } label: {
                        if index == player.trackIndex { Label(entry.title, systemImage: "speaker.wave.2") } else { Text(entry.title) }
                    }
                }
            }
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            if player.chapters.count > 1 {
                Menu("Chapters", systemImage: "list.bullet") {
                    ForEach(player.chapters) { chapter in
                        Button {
                            player.jump(to: chapter)
                        } label: {
                            if chapter == player.currentChapter { Label(chapter.title, systemImage: "speaker.wave.2") } else { Text(chapter.title) }
                        }
                    }
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Menu {
                Picker("Speed", selection: Binding(get: { player.rate }, set: { player.rate = $0 })) {
                    ForEach(AudiobookPlayer.rates, id: \.self) { Text(Self.rateLabel($0)).tag($0) }
                }
            } label: {
                Text(Self.rateLabel(player.rate)).monospacedDigit()
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Speed")
            Menu("Sleep Timer", systemImage: player.sleepTimer == nil ? "moon" : "moon.fill") {
                ForEach(SleepTimer.choices, id: \.self) { choice in
                    Button(choice.label) { player.setSleepTimer(choice) }
                }
                if player.sleepTimer != nil {
                    Divider()
                    Button("Off") { player.setSleepTimer(nil) }
                }
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private static func rateLabel(_ rate: Float) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    private static func time(_ seconds: Double) -> String {
        Duration.seconds(max(seconds, 0)).formatted(seconds >= 3600 ? .time(pattern: .hourMinuteSecond) : .time(pattern: .minuteSecond))
    }
}

/// The system's output picker (AirPlay speakers, HomePods, Bluetooth), the Mac form of the iPhone's route button.
private struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}
