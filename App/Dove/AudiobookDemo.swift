#if DEBUG
import AVFoundation
import DoveKit
import Foundation

/// Debug builds only: `-demoAudiobook` at launch plays a made-up book of three short tone files through the real
/// player path (`AudiobookTracks`, `AudiobookPlayer`), so the player can be tried on the Simulator without a service.
@MainActor
enum AudiobookDemo {
    static let argument = "-demoAudiobook"
    private static let itemID = "demo-audiobook"
    private static let directory = URL.cachesDirectory.appending(path: "Dove/DemoAudiobook")

    static func startIfRequested(on model: AppModel) {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }
        start(on: model)
    }

    static func start(on model: AppModel) {
        let names = ["Demo Book/CD1/01 - Opening.wav", "Demo Book/CD1/02 - Middle.wav", "Demo Book/CD2/01 - Ending.wav"]
        do {
            for (index, name) in names.enumerated() {
                try writeTone(to: directory.appending(path: name), frequency: 330 + Double(index) * 110, seconds: 20)
            }
        } catch {
            model.audiobook.error = "Demo: \(error.localizedDescription)"
            return
        }
        let item = LibraryItem(
            id: itemID, backend: .torBox, name: "Demo Book", status: .ready,
            files: names.enumerated().map { LibraryFile(id: "demo\($0.offset)", name: $0.element) }
        )
        guard case .success(let tracks) = AudiobookTracks.tracks(in: item.files) else { return }
        let real = model.audiobook.assetProvider
        model.audiobook.assetProvider = { item, track in
            if item.id == itemID { return AVURLAsset(url: directory.appending(path: track.path)) }
            guard let real else { throw CancellationError() }
            return try await real(item, track)
        }
        model.audiobook.start(AudiobookPlayer.Session(
            key: "audiobook|demo|demobook", title: "Demo Book", author: "Dove",
            cover: URL(string: "https://covers.openlibrary.org/b/id/10521270-L.jpg"),
            item: item, tracks: tracks
        ))
        model.audiobook.isPresented = true
    }

    private static func writeTone(to url: URL, frequency: Double, seconds: Double) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rate = 22_050.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * seconds))
        else { return }
        buffer.frameLength = buffer.frameCapacity
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(buffer.frameLength) {
            // A beep every second, so playback and seeking can be heard.
            let time = Double(frame) / rate
            let gate = time.truncatingRemainder(dividingBy: 1) < 0.3 ? 0.3 : 0.0
            samples[frame] = Float(sin(2 * .pi * frequency * time) * gate)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
#endif
