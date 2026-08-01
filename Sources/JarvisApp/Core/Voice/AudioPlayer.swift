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

    func stop() {
        player?.stop()
        isPlaying = false
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        onFinish?()
    }
}
