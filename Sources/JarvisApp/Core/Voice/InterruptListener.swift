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
    /// Requiring "jarvis" before "calla" makes a false positive essentially
    /// impossible — including from Jarvis's own voice echoing back through
    /// the speaker into the mic, which is unavoidable here (there's no
    /// hardware echo cancellation in this setup) and is why a single common
    /// word like "calla" on its own wasn't dependable.
    private static let triggerPhrase = "jarvis calla"

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var onTrigger: (() -> Void)?

    /// Starts listening for the phrase. Silently does nothing if anything
    /// isn't available — this is a convenience, never worth surfacing an
    /// error or blocking a reply over.
    func start(onTrigger: @escaping () -> Void) {
        guard task == nil else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVAudioSession.sharedInstance().recordPermission == .granted,
              let recognizer, recognizer.isAvailable else { return }

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
                  Self.containsTrigger(heard) else { return }
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

    /// Accent-, case- and punctuation-insensitive, since speech transcripts
    /// carry no punctuation and may or may not capitalise the name.
    private static func containsTrigger(_ text: String) -> Bool {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let scrubbed = String(folded.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        let collapsed = scrubbed.split(separator: " ").joined(separator: " ")
        return collapsed.contains(triggerPhrase)
    }
}
