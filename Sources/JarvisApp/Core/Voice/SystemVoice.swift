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
            utterance.voice = Self.bestSpanishVoice()
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

    /// Voice picked by hand (see the "Carlos" comparison against Edge TTS) —
    /// checked before any automatic ranking. Matched by name rather than by
    /// `identifier` so it still applies after the OS swaps a downloaded
    /// voice for its Enhanced/Premium version under the hood; matched
    /// case-insensitively and ignoring any "(Mejorada)"/"(Enhanced)" suffix
    /// for the same reason the Mac-voice scripts do it.
    private static let preferredVoiceName = "Carlos"

    /// Picks the best Spanish voice actually installed, rather than whatever
    /// `AVSpeechSynthesisVoice(language:)` defaults to — that's the compact
    /// voice, the robotic one people think of as "the iPhone voice".
    ///
    /// iOS ships far better Enhanced/Premium voices, but only once the user
    /// downloads them (Ajustes → Accesibilidad → Contenido hablado → Voces).
    /// Preferring them here means that download alone noticeably improves how
    /// Jarvis sounds, with no code or account involved. Falls back through
    /// quality tiers, and to any Spanish variant if es-ES isn't present.
    private static func bestSpanishVoice() -> AVSpeechSynthesisVoice? {
        let spanish = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("es") }
        guard !spanish.isEmpty else { return AVSpeechSynthesisVoice(language: "es-ES") }

        func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
            let quality: Int
            switch voice.quality {
            case .premium: quality = 3
            case .enhanced: quality = 2
            default: quality = 1
            }
            // Same quality, prefer peninsular Spanish over other variants.
            return quality * 2 + (voice.language == "es-ES" ? 1 : 0)
        }

        func baseName(_ voice: AVSpeechSynthesisVoice) -> String {
            voice.name.replacingOccurrences(of: #"\s*\(.*\)\s*$"#, with: "", options: .regularExpression)
        }

        let preferred = spanish
            .filter { baseName($0).caseInsensitiveCompare(preferredVoiceName) == .orderedSame }
            .max { rank($0) < rank($1) }
        if let preferred { return preferred }

        return spanish.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: "es-ES")
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
