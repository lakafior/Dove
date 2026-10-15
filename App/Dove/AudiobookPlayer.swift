import AVFoundation
import DoveKit
import MediaPlayer
import Observation
import UIKit

/// Dove's own audiobook player. Video goes to Infuse and friends, but no app takes an audiobook as a link and keeps
/// its place, so audio plays here: one `AVPlayer`, track after track (a single `.m4b`, or a release of many `.mp3`
/// parts), with the place saved per book (`AudiobookPositions`, synced through the Keychain), speed, a sleep timer,
/// chapters, and the lock screen and headphone controls.
@MainActor
@Observable
final class AudiobookPlayer {
    struct Session: Equatable {
        /// `BookGuess.key`: positions follow the book, not the release.
        let key: String
        let title: String
        let author: String?
        let cover: URL?
        let item: LibraryItem
        let tracks: [AudiobookTrack]
    }

    private(set) var session: Session?
    private(set) var trackIndex = 0
    private(set) var elapsed: Double = 0
    private(set) var duration: Double?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    var error: String?
    /// The full-screen player.
    var isPresented = false

    /// Per device, like the chosen video player.
    var rate: Float {
        didSet {
            UserDefaults.standard.set(rate, forKey: Self.rateKey)
            player.defaultRate = rate
            if player.rate != 0 { player.rate = rate }
            updateNowPlaying()
        }
    }

    private(set) var sleepTimer: SleepTimer?
    private(set) var sleepDeadline: Date?
    /// The chapter "end of chapter" waits for.
    private var sleepChapter: AudiobookChapter?

    /// m4b chapter marks per track, once the track was opened. Tracks without marks are one chapter each.
    private var trackChapters: [Int: [AudiobookChapter]] = [:]

    /// Opens a track: the downloaded copy when there is one, else the service's link (with its headers, e.g.
    /// nzbdav's WebDAV login). Set by `AppModel`.
    @ObservationIgnored var assetProvider: (@MainActor (LibraryItem, AudiobookTrack) async throws -> AVURLAsset)?

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private var positions: AudiobookPositions
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var prefetched: (index: Int, asset: AVURLAsset)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var lastKeychainSave = Date.distantPast
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var commandsInstalled = false

    private static let rateKey = "audiobookRate"
    static let rates: [Float] = [0.8, 1, 1.1, 1.2, 1.3, 1.5, 1.75, 2, 2.5, 3]

    init(keychain: KeychainStore) {
        self.keychain = keychain
        positions = SharedConfiguration.audiobookPositions(from: keychain)
        let stored = UserDefaults.standard.float(forKey: Self.rateKey)
        rate = stored > 0 ? stored : 1
        player.defaultRate = rate
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPlayingState() }
        }
    }

    // MARK: - State

    var currentTrack: AudiobookTrack? {
        session.flatMap { $0.tracks.indices.contains(trackIndex) ? $0.tracks[trackIndex] : nil }
    }

    /// Every chapter of the book: m4b marks where the track was opened, else one per track.
    var chapters: [AudiobookChapter] {
        guard let session else { return [] }
        return session.tracks.indices.flatMap { index in
            trackChapters[index] ?? [AudiobookChapter(trackIndex: index, title: session.tracks[index].title, start: 0, duration: nil)]
        }
    }

    var currentChapter: AudiobookChapter? {
        AudiobookChapter.current(in: chapters, trackIndex: trackIndex, seconds: elapsed)
    }

    /// Bumped whenever the saved positions change in a way lists show (a book started, cleared or finished), so
    /// "Listening" on the home screen updates without redrawing on every tick.
    private(set) var positionsRevision = 0

    /// Books being listened to, last played first; the current one with its live position.
    func listening() -> [(key: String, position: AudiobookPosition)] {
        _ = positionsRevision
        var list = positions.listening
        if let session, let live = savedPosition(for: session.key) {
            list.removeAll { $0.key == session.key }
            list.insert((session.key, live), at: 0)
        }
        return list
    }

    /// Forgets where the book was: off "Listening", and Play starts from the beginning. Stops it if it is playing.
    func clearPosition(for key: String) {
        if session?.key == key { stop(saving: false) }
        positions.set(nil, for: key)
        SharedConfiguration.saveAudiobookPositions(positions, to: keychain)
        positionsRevision += 1
    }

    /// Where this book was left, for "Continue" on its screen.
    func savedPosition(for key: String) -> AudiobookPosition? {
        _ = positionsRevision
        if session?.key == key, let track = currentTrack {
            return AudiobookPosition(trackPath: track.path, trackIndex: trackIndex, seconds: elapsed)
        }
        return positions[key]
    }

    // MARK: - Playing

    /// Starts a book where it was left (or plays/pauses it when it is already the current one).
    func start(_ session: Session) {
        if self.session?.key == session.key, self.session?.item.id == session.item.id {
            if !isPlaying { play() }
            return
        }
        savePosition(force: true)
        player.pause()
        self.session = session
        trackChapters = [:]
        prefetched = nil
        artwork = nil
        error = nil
        cancelSleepTimer()
        let resume = positions[session.key]?.resume(in: session.tracks) ?? (index: 0, seconds: 0)
        positionsRevision += 1
        // A few seconds back: picking up mid-sentence is hard to follow.
        load(resume.index, at: max(0, resume.seconds - 3), autoplay: true)
        loadArtwork(session.cover)
        installRemoteCommands()
    }

    func play() {
        guard session != nil else { return }
        if player.currentItem == nil {
            load(trackIndex, at: elapsed, autoplay: true)
            return
        }
        activateAudioSession()
        player.playImmediately(atRate: rate)
        syncPlayingState()
    }

    func pause() {
        player.pause()
        syncPlayingState()
        savePosition(force: true)
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Ends the session: the place is kept for next time.
    func stop(saving: Bool = true) {
        if saving { savePosition(force: true) }
        player.pause()
        player.replaceCurrentItem(with: nil)
        loadTask?.cancel()
        session = nil
        isPlaying = false
        isPresented = false
        cancelSleepTimer()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Seconds within the current track; past the end goes on to the next track.
    func seek(to seconds: Double) {
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

    func skip(by seconds: Double) {
        if elapsed + seconds < 0, trackIndex > 0 {
            // Back into the previous part: its end, minus what is left of the jump.
            let overshoot = elapsed + seconds
            load(trackIndex - 1, at: nil, fromEnd: -overshoot, autoplay: isPlaying)
            return
        }
        seek(to: elapsed + seconds)
    }

    func jump(to chapter: AudiobookChapter) {
        if chapter.trackIndex == trackIndex, player.currentItem != nil {
            seek(to: chapter.start)
            if !isPlaying { play() }
        } else {
            load(chapter.trackIndex, at: chapter.start, autoplay: true)
        }
    }

    func nextChapter() {
        let all = chapters
        guard let current = currentChapter, let index = all.firstIndex(of: current), index + 1 < all.count else { return }
        jump(to: all[index + 1])
    }

    /// The start of this chapter, or the one before when it just started.
    func previousChapter() {
        let all = chapters
        guard let current = currentChapter, let index = all.firstIndex(of: current) else { return }
        if elapsed - current.start > 3 || index == 0 {
            jump(to: current)
        } else {
            jump(to: all[index - 1])
        }
    }

    // MARK: - Sleep timer

    func setSleepTimer(_ timer: SleepTimer?) {
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
        guard let session, session.tracks.indices.contains(index) else { return }
        loadTask?.cancel()
        let track = session.tracks[index]
        trackIndex = index
        elapsed = seconds ?? 0
        duration = nil
        isLoading = true
        error = nil
        loadTask = Task {
            defer { if !Task.isCancelled { isLoading = false } }
            do {
                let asset: AVURLAsset
                if let prefetched, prefetched.index == index {
                    asset = prefetched.asset
                    self.prefetched = nil
                } else {
                    guard let assetProvider else { return }
                    asset = try await assetProvider(session.item, track)
                }
                guard !Task.isCancelled, self.session == session else { return }
                let item = AVPlayerItem(asset: asset)
                // Keeps voices natural at 2× and more.
                item.audioTimePitchAlgorithm = .timeDomain
                observeEnd(of: item)
                player.replaceCurrentItem(with: item)
                let length = try? await asset.load(.duration).seconds
                guard !Task.isCancelled, self.session == session else { return }
                duration = length.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                var start = seconds ?? 0
                if let fromEnd, let duration { start = max(0, duration - fromEnd) }
                if start > 0 {
                    elapsed = start
                    await player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
                if autoplay {
                    activateAudioSession()
                    player.playImmediately(atRate: rate)
                }
                syncPlayingState()
                await loadChapters(of: asset, track: index)
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
        guard let session, session.tracks.indices.contains(index), let assetProvider else { return }
        Task {
            guard let asset = try? await assetProvider(session.item, session.tracks[index]),
                  self.session == session, trackIndex == index - 1
            else { return }
            prefetched = (index, asset)
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

    /// On to the next part; after the last one the book is done and starts over next time.
    private func advance() {
        guard let session else { return }
        if trackIndex + 1 < session.tracks.count {
            load(trackIndex + 1, at: 0, autoplay: true)
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
        guard let session, let track = currentTrack, player.currentItem != nil else { return }
        positions.set(AudiobookPosition(trackPath: track.path, trackIndex: trackIndex, seconds: elapsed), for: session.key)
        if force || Date.now.timeIntervalSince(lastKeychainSave) > 60 {
            lastKeychainSave = .now
            SharedConfiguration.saveAudiobookPositions(positions, to: keychain)
        }
    }

    // MARK: - System

    private func activateAudioSession() {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        try? audio.setActive(true)
    }

    private func loadArtwork(_ url: URL?) {
        guard let url else { return }
        Task {
            guard let data = try? await ImageCache.shared.data(for: url), let image = UIImage(data: data) else { return }
            artwork = Self.artwork(image)
            updateNowPlaying()
        }
    }

    private func updateNowPlaying() {
        guard let session else { return }
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

    /// Built outside the main actor: the system asks for the image on a background queue, and a closure made in a
    /// main-actor method would trap there.
    nonisolated private static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
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
        Self.on(center.nextTrackCommand) { [weak self] in self?.nextChapter() }
        Self.on(center.previousTrackCommand) { [weak self] in self?.previousChapter() }
        Self.onPosition(center.changePlaybackPositionCommand) { [weak self] in self?.seek(to: $0) }
        center.changePlaybackRateCommand.supportedPlaybackRates = Self.rates.map { NSNumber(value: $0) }
        Self.onRate(center.changePlaybackRateCommand) { [weak self] in self?.rate = $0 }
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
