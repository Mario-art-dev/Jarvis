import Foundation
import AVFoundation
import Combine

final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying: Bool = false

    private var player: AVAudioPlayer?
    private var onFinish: (() -> Void)?

    func play(data: Data, onFinish: (() -> Void)? = nil) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)

            player = try AVAudioPlayer(data: data)
            player?.delegate = self
            self.onFinish = onFinish
            player?.play()
            isPlaying = true
        } catch {
            isPlaying = false
            onFinish?()
        }
    }

    /// Stops playback and, crucially, still fires `onFinish` — unlike the
    /// natural-completion path, calling `player.stop()` alone does NOT
    /// invoke `audioPlayerDidFinishPlaying`, so without this a caller
    /// awaiting the completion (see ConversationEngine.speak) would hang
    /// forever whenever playback is cut short (ej. app backgrounded).
    func stop() {
        player?.stop()
        isPlaying = false
        let finish = onFinish
        onFinish = nil
        finish?()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        let finish = onFinish
        onFinish = nil
        finish?()
    }
}
