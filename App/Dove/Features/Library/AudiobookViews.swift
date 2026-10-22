import AVKit
import DoveAppCore
import DoveKit
import SwiftUI

/// Play or Continue on an audiobook's screen: the first ready release with playable audio goes to the player.
struct AudiobookPlaySection: View {
    @Environment(AppModel.self) private var model
    let book: BookTitle
    @State private var isPreparing = false
    @State private var message: String?

    private var player: AudiobookPlayer { model.audiobook }
    private var isCurrent: Bool { player.session?.key == book.guess.key }
    private var saved: AudiobookPosition? { player.savedPosition(for: book.guess.key) }

    var body: some View {
        Section {
            Button {
                if isCurrent { player.isPresented = true } else { start() }
            } label: {
                HStack {
                    Label(title, systemImage: isCurrent && player.isPlaying ? "waveform" : "play.fill")
                        .font(.body.weight(.semibold))
                    Spacer()
                    if isPreparing { ProgressView() }
                }
            }
            .disabled(isPreparing)
            if saved != nil {
                Button("Start over", systemImage: "backward.end.alt") { startOver() }
                    .disabled(isPreparing)
            }
        } footer: {
            if let message {
                Text(message)
            } else if let saved, !isCurrent {
                Text("Left at \(savedDescription(saved)).")
            }
        }
    }

    private var title: String {
        if isCurrent { return player.isPlaying ? "Now playing" : "Open player" }
        return saved == nil ? "Play" : "Continue"
    }

    private func savedDescription(_ position: AudiobookPosition) -> String {
        let time = Duration.seconds(position.seconds).formatted(.time(pattern: position.seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
        let name = ((position.trackPath as NSString).lastPathComponent as NSString).deletingPathExtension
        return "\(name), \(time)"
    }

    private func start() {
        isPreparing = true
        message = nil
        Task {
            message = await model.playAudiobook(book)
            isPreparing = false
        }
    }

    private func startOver() {
        player.clearPosition(for: book.guess.key)
        start()
    }
}

/// Above the tab bar while a book is loaded: cover, title, chapter, play/pause. A tap opens the player.
struct AudiobookMiniPlayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.audiobook
        if let session = player.session {
            let entry = player.currentEntry
            HStack(spacing: 12) {
                CachedImage(url: session.isMusic ? entry?.cover : session.cover) { Rectangle().fill(.quaternary) }
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.isMusic ? entry?.title ?? session.title : session.title)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(session.isMusic ? entry?.artist ?? "" : player.currentChapter?.title ?? session.author ?? "")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if player.isLoading {
                    ProgressView()
                } else {
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                }
                if session.isMusic {
                    Button { player.nextTrack() } label: { Image(systemName: "forward.fill").font(.title3) }
                        .accessibilityLabel("Next track")
                } else {
                    Button { player.skip(by: 30) } label: { Image(systemName: "goforward.30").font(.title3) }
                        .accessibilityLabel("Forward 30 seconds")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            .onTapGesture { player.isPresented = true }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }
}

extension View {
    /// Every tab shows the mini player above the tab bar.
    func audiobookMiniPlayer() -> some View {
        safeAreaInset(edge: .bottom) { AudiobookMiniPlayer() }
    }
}

/// The full player: cover, chapter, scrubber, ±15/30 s, chapters, speed, sleep timer, AirPlay.
struct AudiobookPlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing: Double?
    @State private var showsChapters = false
    @State private var showsQueue = false

    var body: some View {
        let player = model.audiobook
        NavigationStack {
            if let session = player.session, session.isMusic {
                musicPlayer(player, session)
            } else if let session = player.session {
                VStack(spacing: 18) {
                    CachedImage(url: session.cover) {
                        RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                            .overlay { Image(systemName: "headphones").font(.largeTitle).foregroundStyle(.secondary) }
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 12, y: 6)
                    .padding(.horizontal, 24)
                    .frame(maxHeight: 340)

                    VStack(spacing: 4) {
                        Text(session.title).font(.title3.bold()).multilineTextAlignment(.center).lineLimit(2)
                        if let author = session.author { Text(author).foregroundStyle(.secondary) }
                        Text(chapterLine(player, session)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }

                    scrubber(player)

                    HStack(spacing: 34) {
                        Button { player.previousChapter() } label: { Image(systemName: "backward.end.fill") }
                            .accessibilityLabel("Previous chapter")
                        Button { player.skip(by: -15) } label: { Image(systemName: "gobackward.15") }
                            .accessibilityLabel("Back 15 seconds")
                        Button { player.togglePlayPause() } label: {
                            ZStack {
                                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 64))
                                    .opacity(player.isLoading ? 0.3 : 1)
                                if player.isLoading { ProgressView() }
                            }
                        }
                        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                        Button { player.skip(by: 30) } label: { Image(systemName: "goforward.30") }
                            .accessibilityLabel("Forward 30 seconds")
                        Button { player.nextChapter() } label: { Image(systemName: "forward.end.fill") }
                            .accessibilityLabel("Next chapter")
                    }
                    .font(.title2)
                    .buttonStyle(.plain)

                    if let error = player.error {
                        Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    }

                    HStack {
                        speedMenu(player)
                        Spacer()
                        sleepMenu(player)
                        Spacer()
                        Button { showsChapters = true } label: {
                            Label("Chapters", systemImage: "list.bullet")
                        }
                        Spacer()
                        RoutePicker().frame(width: 34, height: 34)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 8)
                    Spacer(minLength: 0)
                }
                .padding()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "chevron.down") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu("More", systemImage: "ellipsis.circle") {
                            Button("Stop and close", systemImage: "xmark.circle", role: .destructive) {
                                player.stop()
                            }
                        }
                    }
                }
                .sheet(isPresented: $showsChapters) { ChapterList() }
            } else {
                ContentUnavailableView("Nothing playing", systemImage: "headphones")
            }
        }
    }

    /// Music: the track's cover and names, previous/next track, shuffle and the queue instead of speed and chapters.
    private func musicPlayer(_ player: AudiobookPlayer, _ session: AudiobookPlayer.Session) -> some View {
        let entry = player.currentEntry
        return VStack(spacing: 18) {
            CachedImage(url: entry?.cover ?? session.cover) {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                    .overlay { Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary) }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 12, y: 6)
            .padding(.horizontal, 24)
            .frame(maxHeight: 340)

            VStack(spacing: 4) {
                Text(entry?.title ?? session.title).font(.title3.bold()).multilineTextAlignment(.center).lineLimit(2)
                Text([entry?.artist, entry?.album].compactMap { $0 }.joined(separator: " — "))
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
                Text("\(player.trackIndex + 1) of \(session.queue.count) · \(session.title)")
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }

            scrubber(player)

            HStack(spacing: 44) {
                Button { player.previousTrack() } label: { Image(systemName: "backward.fill") }
                    .accessibilityLabel("Previous track")
                Button { player.togglePlayPause() } label: {
                    ZStack {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                            .opacity(player.isLoading ? 0.3 : 1)
                        if player.isLoading { ProgressView() }
                    }
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.nextTrack() } label: { Image(systemName: "forward.fill") }
                    .accessibilityLabel("Next track")
                    .disabled(player.trackIndex + 1 >= session.queue.count)
            }
            .font(.title)
            .buttonStyle(.plain)

            if let error = player.error {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            HStack {
                Button { player.setShuffle(!player.isShuffled) } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(player.isShuffled ? Color.accentColor : .secondary)
                }
                .accessibilityLabel(player.isShuffled ? "Shuffle on" : "Shuffle off")
                Spacer()
                sleepMenu(player)
                Spacer()
                Button { showsQueue = true } label: {
                    Label("Queue", systemImage: "list.bullet")
                }
                Spacer()
                RoutePicker().frame(width: 34, height: 34)
            }
            .font(.subheadline)
            .padding(.horizontal, 8)
            Spacer(minLength: 0)
        }
        .padding()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "chevron.down") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Stop and close", systemImage: "xmark.circle", role: .destructive) {
                        player.stop()
                    }
                }
            }
        }
        .sheet(isPresented: $showsQueue) { QueueList() }
    }

    private func chapterLine(_ player: AudiobookPlayer, _ session: AudiobookPlayer.Session) -> String {
        let chapter = player.currentChapter?.title ?? ""
        guard session.tracks.count > 1 else { return chapter }
        return "\(chapter) · part \(player.trackIndex + 1) of \(session.tracks.count)"
    }

    /// Position within the current part (a chapter of an mp3 release, or the whole m4b).
    private func scrubber(_ player: AudiobookPlayer) -> some View {
        let duration = max(player.duration ?? 0, 1)
        let shown = scrubbing ?? player.elapsed
        return VStack(spacing: 4) {
            Slider(
                value: Binding(get: { min(shown, duration) }, set: { scrubbing = $0 }),
                in: 0...duration
            ) { editing in
                if !editing, let scrubbing {
                    player.seek(to: scrubbing)
                    self.scrubbing = nil
                }
            }
            .disabled(player.duration == nil)
            HStack {
                Text(time(shown))
                Spacer()
                if player.rate != 1, player.duration != nil, player.session?.isMusic != true {
                    Text("\(time((duration - shown) / Double(player.rate))) left at \(rateLabel(player.rate))")
                }
                Spacer()
                Text("-" + time(max(0, duration - shown)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func speedMenu(_ player: AudiobookPlayer) -> some View {
        Menu {
            Picker("Speed", selection: Binding(get: { player.rate }, set: { player.rate = $0 })) {
                ForEach(AudiobookPlayer.rates, id: \.self) { Text(rateLabel($0)).tag($0) }
            }
        } label: {
            Text(rateLabel(player.rate)).font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }

    private func sleepMenu(_ player: AudiobookPlayer) -> some View {
        Menu {
            ForEach(SleepTimer.choices, id: \.self) { choice in
                Button(choice.label) { player.setSleepTimer(choice) }
            }
            if player.sleepTimer != nil {
                Button("Off", role: .destructive) { player.setSleepTimer(nil) }
            }
        } label: {
            if let deadline = player.sleepDeadline {
                Label { Text(deadline, style: .timer).monospacedDigit() } icon: { Image(systemName: "moon.zzz.fill") }
            } else if player.sleepTimer == .endOfChapter {
                Label("Chapter end", systemImage: "moon.zzz.fill")
            } else {
                Label("Sleep", systemImage: "moon.zzz")
            }
        }
    }

    private func rateLabel(_ rate: Float) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    private func time(_ seconds: Double) -> String {
        let value = seconds.isFinite ? max(0, seconds) : 0
        return Duration.seconds(value).formatted(.time(pattern: value >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

/// Music: what plays next, in queue order (shuffled when shuffle is on); a tap plays that track.
private struct QueueList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let player = model.audiobook
        let queue = player.session?.queue ?? []
        NavigationStack {
            ScrollViewReader { proxy in
                List(Array(queue.enumerated()), id: \.element.id) { index, entry in
                    Button {
                        player.playEntry(at: index)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            CachedImage(url: entry.cover) { Rectangle().fill(.quaternary) }
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).lineLimit(1)
                                Text([entry.artist, entry.album].compactMap { $0 }.joined(separator: " — "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if index == player.trackIndex {
                                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .tint(.primary)
                    .id(entry.id)
                }
                .onAppear { if let current = player.currentEntry { proxy.scrollTo(current.id, anchor: .center) } }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Every chapter (m4b marks, or one per file); a tap jumps there.
private struct ChapterList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let player = model.audiobook
        let current = player.currentChapter
        NavigationStack {
            ScrollViewReader { proxy in
                List(player.chapters) { chapter in
                    Button {
                        player.jump(to: chapter)
                        dismiss()
                    } label: {
                        HStack {
                            Text(chapter.title).lineLimit(2)
                            Spacer()
                            if chapter == current {
                                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                    .foregroundStyle(.tint)
                            } else if let duration = chapter.duration, duration.isFinite {
                                Text(Duration.seconds(duration).formatted(.time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tint(.primary)
                    .id(chapter.id)
                }
                .onAppear { if let current { proxy.scrollTo(current.id, anchor: .center) } }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// AirPlay and Bluetooth output picker.
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
