import Foundation
import Speech
import AVFoundation

/// Listens for one exact phrase — "Jarvis calla" — while Jarvis is talking,
/// so you can cut him off out loud.
///
/// This is deliberately a separate class with its own SFSpeechRecognizer and
/// its own AVAudioEngine, rather than reusing the main SpeechRecognizer.
/// Two earlier attempts at this feature reused it, and both times the
/// failure wasn't the interrupt detection itself — it was that a mic session
/// left in a bad state by the interrupt watch poisoned the *next* normal
/// listen, so Jarvis stopped hearing the user at all. Keeping the two
/// completely separate means anything that goes wrong here is contained:
/// worst case this silently doesn't work, and normal listening is untouched.
///
/// Two more things differ from those attempts:
///
/// - It never touches the AVAudioSession. AudioPlayer configures the session
///   once for `.playAndRecord` before playback starts and owns it for the
///   whole reply; this just attaches an input tap to the already-configured
///   session. Both sides reconfiguring a shared session was the specific
///   race that made playback cut out silently before.
/// - Recognition is forced on-device, so a slow or missing network can't
///   stall it, and nothing said near the phone while Jarvis talks leaves
///   the device.
@MainActor
final class InterruptListener {
    /// Plain "calla" is what anyone actually says to interrupt, and waiting
    /// for the longer "jarvis calla" costs the better part of a second — so
    /// the short form is accepted, and the false positive it used to risk is
    /// handled directly instead of designed around.
    ///
    /// That risk was only ever Jarvis's own voice echoing back through the
    /// speaker into the mic (there's no hardware echo cancellation here), so
    /// it only exists when Jarvis is itself saying the word. `start` takes
    /// the text being spoken: if that text contains "calla", this falls back
    /// to requiring the full "jarvis calla" for that one reply, which Jarvis
    /// will not say by accident. Every other reply — the overwhelming
    /// majority — stops on a bare "calla".
    private static let shortPhrase = "calla"
    private static let fullPhrase = "jarvis calla"

    /// Set per-reply by `start`. True when Jarvis's own words include the
    /// trigger, and only then is the longer phrase required.
    private var requiresFullPhrase = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var onTrigger: (() -> Void)?

    /// Starts listening for the phrase. Silently does nothing if anything
    /// isn't available — this is a convenience, never worth surfacing an
    /// error or blocking a reply over.
    ///
    /// `whileSaying` is the text Jarvis is about to speak, used only to
    /// decide whether a bare "calla" can be trusted for this reply (see
    /// `shortPhrase`).
    func start(whileSaying spokenText: String = "", onTrigger: @escaping () -> Void) {
        guard task == nil else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVAudioSession.sharedInstance().recordPermission == .granted,
              let recognizer, recognizer.isAvailable else { return }

        requiresFullPhrase = Self.normalize(spokenText).contains(Self.shortPhrase)
        self.onTrigger = onTrigger

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            newRequest.requiresOnDeviceRecognition = true
        }
        request = newRequest

        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // A zero sample rate means the input hardware isn't actually
        // available to us right now; installing a tap with that format
        // throws an uncatchable exception, so bail out instead.
        guard format.sampleRate > 0 else {
            stop()
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak newRequest] buffer, _ in
            newRequest?.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            return
        }

        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            guard let self else { return }
            if error != nil {
                self.stop()
                return
            }
            guard let heard = result?.bestTranscription.formattedString,
                  self.containsTrigger(heard) else { return }
            let callback = self.onTrigger
            self.stop()
            callback?()
        }
    }

    func stop() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        onTrigger = nil
        // Deliberately does NOT deactivate the audio session — AudioPlayer
        // owns it for the duration of the reply (see the class comment).
    }

    /// Bare "calla" normally, the full "jarvis calla" only for a reply whose
    /// own text says "calla" and could therefore trigger itself.
    private func containsTrigger(_ text: String) -> Bool {
        let heard = Self.normalize(text)
        return requiresFullPhrase
            ? heard.contains(Self.fullPhrase)
            : heard.contains(Self.shortPhrase)
    }

    /// Accent-, case- and punctuation-insensitive, since speech transcripts
    /// carry no punctuation and may or may not capitalise the name.
    private static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let scrubbed = String(folded.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        return scrubbed.split(separator: " ").joined(separator: " ")
    }
}
