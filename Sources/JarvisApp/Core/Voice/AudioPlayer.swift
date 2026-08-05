import Foundation
import AVFoundation
import Combine

final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying: Bool = false
    /// Rough 0...1 output level while playing, sampled via AVAudioPlayer's
    /// metering — drives the HUD waveform while Jarvis talks, same idea as
    /// SpeechRecognizer.audioLevel while listening.
    @Published var audioLevel: Float = 0

    private var player: AVAudioPlayer?
    private var onFinish: (() -> Void)?
    private var meterTimer: Timer?

    func play(data: Data, onFinish: (() -> Void)? = nil) {
        do {
            // .playAndRecord (not plain .playback) so InterruptListener can
            // attach a mic tap and hear "Jarvis calla" over the top of this.
            //
            // This is configured here, once, before playback starts, and
            // nothing else touches the session for the rest of the reply —
            // InterruptListener deliberately only attaches an input tap. Two
            // components independently reconfiguring a live shared session
            // was the exact race that used to cut playback off silently, so
            // there is now a single owner of it at any moment.
            //
            // .default rather than .voiceChat: the latter is tuned for
            // audio held to your ear and noticeably quietens output even
            // with .defaultToSpeaker set, which once made Jarvis almost
            // inaudible on speaker.
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            player = try AVAudioPlayer(data: data)
            player?.delegate = self
            player?.isMeteringEnabled = true
            self.onFinish = onFinish
            player?.play()
            isPlaying = true
            startMetering()
        } catch {
            isPlaying = false
            onFinish?()
        }
    }

    /// Stops playback and, crucially, still fires `onFinish` — unlike the
    /// natural-completion path, calling `player.stop()` alone does NOT
    /// invoke `audioPlayerDidFinishPlaying`, so without this a caller
    /// awaiting the completion (see ConversationEngine.speak) would hang
    /// forever whenever playback is cut short (ej. app backgrounded, or the
    /// user barges in while Jarvis is talking).
    func stop() {
        player?.stop()
        isPlaying = false
        stopMetering()
        let finish = onFinish
        onFinish = nil
        finish?()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        stopMetering()
        let finish = onFinish
        onFinish = nil
        finish?()
    }

    private func startMetering() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let player = self.player, player.isPlaying else { return }
            player.updateMeters()
            let db = player.averagePower(forChannel: 0)
            // dB is roughly -60 (quiet) ... 0 (loudest) — map to 0...1.
            let normalized = max(0, min(1, (db + 60) / 60))
            self.audioLevel = normalized
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        audioLevel = 0
    }
}
