import Foundation
import AVFoundation

/// iOS's built-in speech synthesiser, used as a fallback when ElevenLabs
/// can't produce audio — most often because the account ran out of monthly
/// credits, but equally if its API is down or the key is wrong.
///
/// It sounds noticeably more robotic than the cloned voice, but it's free,
/// unlimited and works offline. Falling back to it means a quota running out
/// degrades Jarvis to "sounds worse" instead of "went completely mute", which
/// was otherwise indistinguishable from the app being broken — every action
/// still ran, there was just nothing to tell you so.
@MainActor
final class SystemVoice: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation

            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
                try session.setActive(true)
            } catch {
                // Speaking may still work on whatever the session already
                // was; not worth abandoning the reply over.
            }

            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "es-ES")
            // Slightly quicker than default, to match the pace the ElevenLabs
            // voice is configured for.
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        finish()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    /// Clearing before resuming keeps a cancel-then-finish pair (or a stop()
    /// racing the delegate) from resuming the same continuation twice, which
    /// would crash.
    private func finish() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
