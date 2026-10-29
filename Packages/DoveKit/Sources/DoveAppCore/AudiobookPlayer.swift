import AVFoundation
import DoveKit
import MediaPlayer
import Observation

/// Dove's own audio player. Video goes to Infuse and friends, but no app takes an audiobook as a link and keeps
/// its place, so audio plays here: one `AVPlayer`, track after track (a single `.m4b`, or a release of many `.mp3`
/// parts), with the place saved per book (`AudiobookPositions`, synced through the Keychain), speed, a sleep timer,
/// chapters, and the lock screen and headphone controls.
///
/// Music plays through it too (`Session.Kind.music`): a queue across albums and services (an album, an artist,
/// the whole library), shuffle, next/previous track on the lock screen, each track's own title and cover; no saved
/// place, no speed.
@MainActor
@Observable
public final class AudiobookPlayer {
    public struct Session: Equatable {
        public enum Kind: Equatable { case audiobook, music }

        /// One file to play and the service item it belongs to; music tracks carry their own names and cover.
        public struct Entry: Equatable, Identifiable {
            public let item: LibraryItem
            public let track: AudiobookTrack
            public var title: String
            public var artist: String?
            public var album: String?
            public var cover: URL?
            public var id: String { "\(item.backend.rawValue)/\(item.id)/\(track.fileID)" }
        }

        /// Tells sessions apart while their queue changes (music appends albums as their files arrive, shuffle).
        public let id = UUID()
        public let kind: Kind
        /// Audiobooks: `BookGuess.key` (positions follow the book, not the release). Music: what is playing.
        public let key: String
        public let title: String
        public let author: String?
        public let cover: URL?
        public var queue: [Entry]

        /// An audiobook: one release's files.
        public init(key: String, title: String, author: String?, cover: URL?, item: LibraryItem, tracks: [AudiobookTrack]) {
            kind = .audiobook
            self.key = key
            self.title = title
            self.author = author
            self.cover = cover
            queue = tracks.map { Entry(item: item, track: $0, title: $0.title, artist: author, album: title, cover: cover) }
        }

        /// Music: a queue named after what was played ("Dookie", "Green Day", "All music").
        public init(music key: String, title: String, cover: URL?, queue: [Entry]) {
            kind = .music
            self.key = key
            self.title = title
            author = nil
            self.cover = cover
            self.queue = queue
        }

        public var tracks: [AudiobookTrack] { queue.map(\.track) }
        /// The audiobook's release (music sessions span several).
        public var item: LibraryItem? { queue.first?.item }
        public var isMusic: Bool { kind == .music }
    }

    public private(set) var session: Session?
    public private(set) var trackIndex = 0
    /// Music: the queue is played in random order; the albums' order comes back when it is turned off.
    public private(set) var isShuffled = false
    /// Music: the queue in album order, for turning shuffle off.
    @ObservationIgnored private var orderedQueue: [Session.Entry] = []
    public private(set) var elapsed: Double = 0
    public private(set) var duration: Double?
    public private(set) var isPlaying = false
    public private(set) var isLoading = false
    public var error: String?
    /// The full-screen player.
    public var isPresented = false

    /// Per device, like the chosen video player. Audiobooks only: music always plays at 1×.
    public var rate: Float {
        didSet {
            DoveStorage.defaults.set(rate, forKey: Self.rateKey)
            player.defaultRate = playbackRate
            if player.rate != 0 { player.rate = playbackRate }
            updateNowPlaying()
        }
    }

    private var playbackRate: Float { session?.isMusic == true ? 1 : rate }

    public private(set) var sleepTimer: SleepTimer?
    public private(set) var sleepDeadline: Date?
    /// The chapter "end of chapter" waits for.
    private var sleepChapter: AudiobookChapter?

    /// m4b chapter marks per track, once the track was opened. Tracks without marks are one chapter each.
    private var trackChapters: [Int: [AudiobookChapter]] = [:]

    /// Opens a track: the downloaded copy when there is one, else the service's link (with its headers, e.g.
    /// nzbdav's WebDAV login). Set by `AppModel`.
    @ObservationIgnored public var assetProvider: (@MainActor (LibraryItem, AudiobookTrack) async throws -> AVURLAsset)?

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private let platform: any AppPlatform
    @ObservationIgnored private var positions: AudiobookPositions
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var prefetched: (entryID: String, asset: AVURLAsset)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var lastKeychainSave = Date.distantPast
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var artworkURL: URL?
    @ObservationIgnored private var commandsInstalled = false

    private static let rateKey = "audiobookRate"
    public static let rates: [Float] = [0.8, 1, 1.1, 1.2, 1.3, 1.5, 1.75, 2, 2.5, 3]

    /// Reads saved places from the Keychain again (after a settings import).
    public func reloadPositions() {
        positions = SharedConfiguration.audiobookPositions(from: keychain)
    }

    public init(keychain: KeychainStore, platform: any AppPlatform) {
        self.keychain = keychain
        self.platform = platform
        positions = SharedConfiguration.audiobookPositions(from: keychain)
        let stored = DoveStorage.defaults.float(forKey: Self.rateKey)
        rate = stored > 0 ? stored : 1
        player.defaultRate = rate
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPlayingState() }
        }
        #endif
    }

    // MARK: - State

    public var currentTrack: AudiobookTrack? {
        currentEntry?.track
    }

    public var currentEntry: Session.Entry? {
        session.flatMap { $0.queue.indices.contains(trackIndex) ? $0.queue[trackIndex] : nil }
    }

    /// Every chapter of the book: m4b marks where the track was opened, else one per track.
    public var chapters: [AudiobookChapter] {
        guard let session else { return [] }
        return session.tracks.indices.flatMap { index in
            trackChapters[index] ?? [AudiobookChapter(trackIndex: index, title: session.tracks[index].title, start: 0, duration: nil)]
        }
    }

    public var currentChapter: AudiobookChapter? {
        AudiobookChapter.current(in: chapters, trackIndex: trackIndex, seconds: elapsed)
    }

    /// Bumped whenever the saved positions change in a way lists show (a book started, cleared or finished), so
    /// "Listening" on the home screen updates without redrawing on every tick.
    public private(set) var positionsRevision = 0

    /// Books being listened to, last played first; the current one with its live position.
    public func listening() -> [(key: String, position: AudiobookPosition)] {
        _ = positionsRevision
        var list = positions.listening
        if let session, !session.isMusic, let live = savedPosition(for: session.key) {
            list.removeAll { $0.key == session.key }
            list.insert((session.key, live), at: 0)
        }
        return list
    }

    /// Forgets where the book was: off "Listening", and Play starts from the beginning. Stops it if it is playing.
    public func clearPosition(for key: String) {
        if session?.key == key { stop(saving: false) }
        positions.set(nil, for: key)
        SharedConfiguration.saveAudiobookPositions(positions, to: keychain)
        positionsRevision += 1
    }

    /// Where this book was left, for "Continue" on its screen.
    public func savedPosition(for key: String) -> AudiobookPosition? {
        _ = positionsRevision
        if session?.key == key, let track = currentTrack {
            return AudiobookPosition(trackPath: track.path, trackIndex: trackIndex, seconds: elapsed)
        }
        return positions[key]
    }

    // MARK: - Playing

    /// Starts a book where it was left (or plays/pauses it when it is already the current one).
    public func start(_ session: Session) {
        if !session.isMusic, self.session?.key == session.key, self.session?.item?.id == session.item?.id {
            if !isPlaying { play() }
            return
        }
        begin(session)
        let resume = positions[session.key]?.resume(in: session.tracks) ?? (index: 0, seconds: 0)
        positionsRevision += 1
        // A few seconds back: picking up mid-sentence is hard to follow.
        load(resume.index, at: max(0, resume.seconds - 3), autoplay: true)
    }

    /// Plays a music queue from one of its tracks; shuffled, that track plays first and the rest in random order.
    public func startMusic(_ session: Session, at index: Int = 0, shuffled: Bool = false) {
        guard session.isMusic, session.queue.indices.contains(index) else { return }
        begin(session)
        orderedQueue = session.queue
        isShuffled = false
        trackIndex = index
        if shuffled { setShuffle(true) }
        load(trackIndex, at: 0, autoplay: true)
    }

    private func begin(_ session: Session) {
        savePosition(force: true)
        player.pause()
        self.session = session
        trackChapters = [:]
        prefetched = nil
        artwork = nil
        artworkURL = nil
        error = nil
        isShuffled = false
        orderedQueue = []
        cancelSleepTimer()
        player.defaultRate = session.isMusic ? 1 : rate
        installRemoteCommands()
        updateRemoteCommands()
    }

    /// Music: more tracks for the queue (albums whose files arrived after playback started). Shuffled, they go
    /// to random places after the current track.
    public func append(_ entries: [Session.Entry], to sessionID: UUID) {
        guard var session, session.id == sessionID, session.isMusic, !entries.isEmpty else { return }
        orderedQueue += entries
        if isShuffled {
            for entry in entries {
                session.queue.insert(entry, at: Int.random(in: (trackIndex + 1)...session.queue.count))
            }
        } else {
            session.queue += entries
        }
        self.session = session
        if prefetched == nil { prefetch(trackIndex + 1) }
        updateNowPlaying()
    }

    /// Music: shuffle on (the current track stays, the rest in random order) or off (album order, from the
    /// current track).
    public func setShuffle(_ on: Bool) {
        guard var session, session.isMusic, on != isShuffled else { return }
        let current = currentEntry
        if on {
            var rest = session.queue
            if let current, let index = rest.firstIndex(of: current) { rest.remove(at: index) }
            session.queue = (current.map { [$0] } ?? []) + rest.shuffled()
            trackIndex = 0
        } else {
            session.queue = orderedQueue
            trackIndex = current.flatMap { session.queue.firstIndex(of: $0) } ?? 0
        }
        isShuffled = on
        self.session = session
        prefetched = nil
        prefetch(trackIndex + 1)
        updateNowPlaying()
    }

    /// Music: plays a track of the queue.
    public func playEntry(at index: Int) {
        guard let session, session.queue.indices.contains(index) else { return }
        load(index, at: 0, autoplay: true)
    }

    public func nextTrack() {
        guard let session else { return }
        if trackIndex + 1 < session.queue.count { load(trackIndex + 1, at: 0, autoplay: true) }
    }

    /// The start of this track, or the one before when it just started.
    public func previousTrack() {
        if elapsed > 3 || trackIndex == 0 {
            seek(to: 0)
        } else {
            load(trackIndex - 1, at: 0, autoplay: true)
        }
    }

    public func play() {
        guard session != nil else { return }
        if player.currentItem == nil {
            load(trackIndex, at: elapsed, autoplay: true)
            return
        }
        activateAudioSession()
        player.playImmediately(atRate: playbackRate)
        syncPlayingState()
    }

    public func pause() {
        player.pause()
        syncPlayingState()
        savePosition(force: true)
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Ends the session: the place is kept for next time.
    public func stop(saving: Bool = true) {
        if saving { savePosition(force: true) }
        player.pause()
        player.replaceCurrentItem(with: nil)
        loadTask?.cancel()
        session = nil
        isPlaying = false
        isPresented = false
        isShuffled = false
        orderedQueue = []
        cancelSleepTimer()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Seconds within the current track; past the end goes on to the next track.
    public func seek(to seconds: Double) {
        if let duration, seconds >= duration - 0.5 {
            advance()
            return
        }
        let target = max(0, seconds)
        elapsed = target
        Task {
            await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            updateNowPlaying()
            savePosition(force: false)
        }
    }

    public func skip(by seconds: Double) {
        if elapsed + seconds < 0, trackIndex > 0 {
            // Back into the previous part: its end, minus what is left of the jump.
            let overshoot = elapsed + seconds
            load(trackIndex - 1, at: nil, fromEnd: -overshoot, autoplay: isPlaying)
            return
        }
        seek(to: elapsed + seconds)
    }

    public func jump(to chapter: AudiobookChapter) {
        if chapter.trackIndex == trackIndex, player.currentItem != nil {
            seek(to: chapter.start)
            if !isPlaying { play() }
        } else {
            load(chapter.trackIndex, at: chapter.start, autoplay: true)
        }
    }

    public func nextChapter() {
        let all = chapters
        guard let current = currentChapter, let index = all.firstIndex(of: current), index + 1 < all.count else { return }
        jump(to: all[index + 1])
    }

    /// The start of this chapter, or the one before when it just started.
    public func previousChapter() {
        let all = chapters
        guard let current = currentChapter, let index = all.firstIndex(of: current) else { return }
        if elapsed - current.start > 3 || index == 0 {
            jump(to: current)
        } else {
            jump(to: all[index - 1])
        }
    }

    // MARK: - Sleep timer

    public func setSleepTimer(_ timer: SleepTimer?) {
        sleepTimer = timer
        switch timer {
        case .minutes(let minutes):
            sleepDeadline = .now.addingTimeInterval(Double(minutes) * 60)
            sleepChapter = nil
        case .endOfChapter:
            sleepDeadline = nil
            sleepChapter = currentChapter
        case nil:
            sleepDeadline = nil
            sleepChapter = nil
        }
    }

    private func cancelSleepTimer() {
        setSleepTimer(nil)
    }

    private func sleepNow() {
        cancelSleepTimer()
        pause()
    }

    // MARK: - Tracks

    /// Opens a track and seeks: to `seconds`, or `fromEnd` seconds before its end.
    private func load(_ index: Int, at seconds: Double?, fromEnd: Double? = nil, autoplay: Bool) {
        guard let session, session.queue.indices.contains(index) else { return }
        loadTask?.cancel()
        let entry = session.queue[index]
        trackIndex = index
        elapsed = seconds ?? 0
        duration = nil
        isLoading = true
        error = nil
        loadTask = Task {
            defer { if !Task.isCancelled { isLoading = false } }
            do {
                let asset: AVURLAsset
                if let prefetched, prefetched.entryID == entry.id {
                    asset = prefetched.asset
                    self.prefetched = nil
                } else {
                    guard let assetProvider else { return }
                    asset = try await assetProvider(entry.item, entry.track)
                }
                guard !Task.isCancelled, self.session?.id == session.id else { return }
                let item = AVPlayerItem(asset: asset)
                // Keeps voices natural at 2× and more.
                item.audioTimePitchAlgorithm = .timeDomain
                observeEnd(of: item)
                player.replaceCurrentItem(with: item)
                if session.isMusic { loadArtwork(entry.cover) }
                let length = try? await asset.load(.duration).seconds
                guard !Task.isCancelled, self.session?.id == session.id else { return }
                duration = length.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                var start = seconds ?? 0
                if let fromEnd, let duration { start = max(0, duration - fromEnd) }
                if start > 0 {
                    elapsed = start
                    await player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
                if autoplay {
                    activateAudioSession()
                    player.playImmediately(atRate: playbackRate)
                }
                syncPlayingState()
                if !session.isMusic { await loadChapters(of: asset, track: index) }
                prefetch(index + 1)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                isPlaying = false
            }
        }
    }

    /// The next part's link is fetched while this one plays, so moving on has no gap for the service to answer.
    private func prefetch(_ index: Int) {
        guard let session, session.queue.indices.contains(index), let assetProvider else { return }
        let entry = session.queue[index]
        Task {
            guard let asset = try? await assetProvider(entry.item, entry.track),
                  let now = self.session, now.id == session.id,
                  now.queue.indices.contains(trackIndex + 1), now.queue[trackIndex + 1].id == entry.id
            else { return }
            prefetched = (entry.id, asset)
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackEnded() }
        }
    }

    private func trackEnded() {
        if sleepTimer == .endOfChapter {
            sleepNow()
            return
        }
        advance()
    }

    /// On to the next part; after the last one the book is done and starts over next time. Music stops at the
    /// end of the queue and keeps it, ready to play again.
    private func advance() {
        guard let session else { return }
        if trackIndex + 1 < session.queue.count {
            load(trackIndex + 1, at: 0, autoplay: true)
        } else if session.isMusic {
            player.pause()
            syncPlayingState()
            trackIndex = 0
            elapsed = 0
            player.replaceCurrentItem(with: nil)
        } else {
            player.pause()
            syncPlayingState()
            positions.set(nil, for: session.key)
            SharedConfiguration.saveAudiobookPositions(positions, to: keychain)
            positionsRevision += 1
            trackIndex = 0
            elapsed = 0
            player.replaceCurrentItem(with: nil)
        }
    }

    private func loadChapters(of asset: AVURLAsset, track: Int) async {
        guard let groups = try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages),
              groups.count > 1
        else { return }
        var chapters: [AudiobookChapter] = []
        for (number, group) in groups.enumerated() {
            let titleItem = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first
            let title = (try? await titleItem?.load(.stringValue)) ?? nil
            chapters.append(AudiobookChapter(
                trackIndex: track,
                title: title ?? "Chapter \(number + 1)",
                start: group.timeRange.start.seconds,
                duration: group.timeRange.duration.seconds
            ))
        }
        trackChapters[track] = chapters
        updateNowPlaying()
    }

    // MARK: - Clock

    private func tick(_ time: CMTime) {
        guard session != nil, player.currentItem != nil, !isLoading else { return }
        elapsed = time.seconds.isFinite ? time.seconds : 0
        syncPlayingState()
        guard isPlaying else { return }
        if let sleepDeadline, Date.now >= sleepDeadline {
            sleepNow()
            return
        }
        // End of an m4b chapter (between tracks, `trackEnded` handles it).
        if sleepTimer == .endOfChapter, let sleepChapter, let current = currentChapter, current != sleepChapter {
            sleepNow()
            return
        }
        savePosition(force: false)
    }

    private func syncPlayingState() {
        let playing = player.timeControlStatus != .paused
        if playing != isPlaying {
            isPlaying = playing
            if !playing { savePosition(force: true) }
        }
        updateNowPlaying()
    }

    /// In memory every tick; to the Keychain (and so iCloud) every minute and on every pause.
    private func savePosition(force: Bool) {
        guard let session, !session.isMusic, let track = currentTrack, player.currentItem != nil else { return }
        positions.set(AudiobookPosition(trackPath: track.path, trackIndex: trackIndex, seconds: elapsed), for: session.key)
        if force || Date.now.timeIntervalSince(lastKeychainSave) > 60 {
            lastKeychainSave = .now
            SharedConfiguration.saveAudiobookPositions(positions, to: keychain)
        }
    }

    // MARK: - System

    /// macOS has no audio session: apps just play.
    private func activateAudioSession() {
        #if os(iOS)
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: session?.isMusic == true ? .default : .spokenAudio, policy: .longFormAudio)
        try? audio.setActive(true)
        #endif
    }

    private func loadArtwork(_ url: URL?) {
        guard url != artworkURL else { return }
        artworkURL = url
        artwork = nil
        guard let url else { return }
        Task {
            guard let data = try? await ImageCache.shared.data(for: url), artworkURL == url,
                  let image = platform.nowPlayingArtwork(from: data) else { return }
            artwork = image
            updateNowPlaying()
        }
    }

    private func updateNowPlaying() {
        guard let session else { return }
        if session.isMusic {
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: currentEntry?.title ?? session.title,
                MPMediaItemPropertyMediaType: MPMediaType.music.rawValue,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
                MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0,
                MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
                MPNowPlayingInfoPropertyPlaybackQueueIndex: trackIndex,
                MPNowPlayingInfoPropertyPlaybackQueueCount: session.queue.count,
            ]
            if let artist = currentEntry?.artist { info[MPMediaItemPropertyArtist] = artist }
            if let album = currentEntry?.album { info[MPMediaItemPropertyAlbumTitle] = album }
            if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
            if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            return
        }
        let chapter = currentChapter
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapters.count > 1 ? (chapter?.title ?? session.title) : session.title,
            MPMediaItemPropertyAlbumTitle: session.title,
            MPMediaItemPropertyMediaType: MPMediaType.audioBook.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
        ]
        if let author = session.author { info[MPMediaItemPropertyArtist] = author }
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        if session.tracks.count > 1 {
            info[MPNowPlayingInfoPropertyChapterNumber] = trackIndex
            info[MPNowPlayingInfoPropertyChapterCount] = session.tracks.count
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func installRemoteCommands() {
        guard !commandsInstalled else { return }
        commandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        Self.on(center.playCommand) { [weak self] in self?.play() }
        Self.on(center.pauseCommand) { [weak self] in self?.pause() }
        Self.on(center.togglePlayPauseCommand) { [weak self] in self?.togglePlayPause() }
        center.skipForwardCommand.preferredIntervals = [30]
        Self.on(center.skipForwardCommand) { [weak self] in self?.skip(by: 30) }
        center.skipBackwardCommand.preferredIntervals = [15]
        Self.on(center.skipBackwardCommand) { [weak self] in self?.skip(by: -15) }
        Self.on(center.nextTrackCommand) { [weak self] in
            if self?.session?.isMusic == true { self?.nextTrack() } else { self?.nextChapter() }
        }
        Self.on(center.previousTrackCommand) { [weak self] in
            if self?.session?.isMusic == true { self?.previousTrack() } else { self?.previousChapter() }
        }
        Self.onPosition(center.changePlaybackPositionCommand) { [weak self] in self?.seek(to: $0) }
        center.changePlaybackRateCommand.supportedPlaybackRates = Self.rates.map { NSNumber(value: $0) }
        Self.onRate(center.changePlaybackRateCommand) { [weak self] in self?.rate = $0 }
    }

    /// The lock screen shows ±15/30 s and speed for books, previous/next track for music.
    private func updateRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        let book = session?.isMusic != true
        center.skipForwardCommand.isEnabled = book
        center.skipBackwardCommand.isEnabled = book
        center.changePlaybackRateCommand.isEnabled = book
    }

    // Handlers are built outside the main actor and hop to it: a closure made in a main-actor method traps when
    // the system calls it on another queue.

    nonisolated private static func on(_ command: MPRemoteCommand, _ action: @escaping @Sendable @MainActor () -> Void) {
        command.addTarget { _ in
            Task { @MainActor in action() }
            return .success
        }
    }

    nonisolated private static func onPosition(
        _ command: MPChangePlaybackPositionCommand,
        _ action: @escaping @Sendable @MainActor (Double) -> Void
    ) {
        command.addTarget { event in
            guard let time = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in action(time) }
            return .success
        }
    }

    nonisolated private static func onRate(
        _ command: MPChangePlaybackRateCommand,
        _ action: @escaping @Sendable @MainActor (Float) -> Void
    ) {
        command.addTarget { event in
            guard let rate = (event as? MPChangePlaybackRateCommandEvent)?.playbackRate else { return .commandFailed }
            Task { @MainActor in action(rate) }
            return .success
        }
    }
}
