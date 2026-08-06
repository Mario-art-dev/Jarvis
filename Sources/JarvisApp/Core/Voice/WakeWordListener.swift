import Foundation
import Speech
import AVFoundation

/// Listens for "Jarvis escucha" while Jarvis is idle and the app is
/// backgrounded (screen locked, app not force-quit) — the on-device
/// equivalent of "Hey Jarvis", built with the same Speech framework already
/// used everywhere else in the app rather than a third-party wake-word SDK,
/// so it needs no account, no API key and no extra dependency.
///
/// In the foreground this deliberately never gets a chance to run: Jarvis
/// already listens continuously whenever the app is open and idle (see
/// ConversationView.beginListeningIfIdle), so a wake word would be pure
/// overhead there. Its entire reason to exist is the background case, where
/// nothing else is listening for you at all.
///
/// Own SFSpeechRecognizer and own AVAudioEngine, exactly like
/// InterruptListener and for the same reason: two earlier features that
/// reused the main SpeechRecognizer each left a mic session in a bad state
/// that poisoned the *next* normal listen, which was far worse than the
/// original feature not working. Total isolation contains that risk —
/// worst case here is silently not detecting the phrase, never breaking
/// anything else.
///
/// Unlike InterruptListener, this one *does* own configuring the audio
/// session — it only ever runs when nothing else is (Jarvis idle), so
/// there's no session already set up to inherit. It uses the exact same
/// category/mode/options as AudioPlayer/SpeechRecognizer/SystemVoice so
/// handing off to any of them afterwards needs no reconfiguration (see the
/// click/pop fix elsewhere in this file's siblings) — a mismatch there was
/// once audible as a click on every single turn.
@MainActor
final class WakeWordListener: NSObject {
    private static let triggerPhrase = "jarvis escucha"

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var onTrigger: (() -> Void)?

    var isArmed: Bool { task != nil }

    /// Starts listening for the phrase. Silently does nothing if anything
    /// isn't available (permissions not yet granted, recognizer momentarily
    /// unavailable, mic hardware not free) — this only ever runs
    /// unattended, so there's no one to show an error to, and the app must
    /// keep working normally regardless of whether this succeeds.
    func start(onTrigger: @escaping () -> Void) {
        guard task == nil else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVAudioSession.sharedInstance().recordPermission == .granted,
              let recognizer, recognizer.isAvailable else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            return
        }

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
        // available right now (ej. mid-transition between apps owning the
        // mic) — installing a tap with that format throws an uncatchable
        // exception, so bail out instead.
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
        // Deactivating here (unlike InterruptListener, which never touches
        // the session) is correct specifically because this is the only
        // thing using the session while armed — whoever runs next
        // (SpeechRecognizer, AudioPlayer, SystemVoice) configures it fresh
        // for themselves regardless, so there's no shared state to protect
        // by leaving it active.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Accent-, case- and punctuation-insensitive, same approach as
    /// InterruptListener's "jarvis calla" matching.
    private static func containsTrigger(_ text: String) -> Bool {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let scrubbed = String(folded.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        let collapsed = scrubbed.split(separator: " ").joined(separator: " ")
        return collapsed.contains(triggerPhrase)
    }
}
