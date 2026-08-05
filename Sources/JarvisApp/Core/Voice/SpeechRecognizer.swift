import Foundation
import Speech
import AVFoundation
import Combine

/// Wraps SFSpeechRecognizer + AVAudioEngine for push-to-talk style dictation.
/// True always-on "Hey Jarvis" wake word needs a background wake-word engine
/// (e.g. Picovoice Porcupine) layered on top of this — plain Speech framework
/// recognition cannot run indefinitely in the background on iOS.
final class SpeechRecognizer: NSObject, ObservableObject {
    @Published var transcript: String = "" {
        didSet { lastTranscriptChange = Date() }
    }
    @Published var isListening: Bool = false
    @Published var errorMessage: String?
    /// Rough 0...1 input level from the mic, sampled from the same tap that
    /// feeds recognition — used to animate the HUD waveform. Not calibrated
    /// audio metering, just "how loud is it right now" for a visual effect.
    @Published var audioLevel: Float = 0

    /// When the transcript last changed — used to detect "user stopped
    /// talking" for continuous listening (no mic button needed) instead of
    /// waiting for SFSpeechRecognizer's own end-of-utterance signal, which
    /// is unreliable for open-ended conversation.
    private(set) var lastTranscriptChange = Date()

    func secondsSinceLastTranscriptChange() -> TimeInterval {
        Date().timeIntervalSince(lastTranscriptChange)
    }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    /// True once both Speech and mic permission are already granted — lets
    /// requestAuthorization skip the async system call entirely and
    /// complete synchronously instead, which is the overwhelmingly common
    /// case after first launch.
    var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
            && AVAudioSession.sharedInstance().recordPermission == .granted
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        if isAuthorized {
            completion(true)
            return
        }
        SFSpeechRecognizer.requestAuthorization { status in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    completion(status == .authorized && granted)
                }
            }
        }
    }

    func startListening() {
        guard !isListening else { return }
        guard let recognizer = recognizer else {
            errorMessage = "El reconocimiento de voz no está disponible ahora mismo."
            return
        }
        guard recognizer.isAvailable else {
            // SFSpeechRecognizer can report unavailable for a brief moment
            // right after a previous recognition task just ended — which,
            // with how often this app starts/stops listening, happens
            // often enough to matter. Without this retry it used to fail
            // silently here while the caller had already optimistically
            // marked the UI as "listening", leaving Jarvis looking frozen
            // with a mic that never actually started. One retry after a
            // brief pause covers the transient case; if it's still
            // unavailable after that, errorMessage below lets
            // ConversationView notice and recover instead of staying stuck.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.retryStartListening()
            }
            return
        }
        beginListening(with: recognizer)
    }

    private func retryStartListening() {
        guard !isListening else { return }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            errorMessage = "El reconocimiento de voz no está disponible ahora mismo."
            return
        }
        beginListening(with: recognizer)
    }

    private func beginListening(with recognizer: SFSpeechRecognizer) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let newRequest = SFSpeechAudioBufferRecognitionRequest()
            newRequest.shouldReportPartialResults = true
            request = newRequest

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.request?.append(buffer)
                self?.updateAudioLevel(from: buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            errorMessage = nil
            transcript = ""

            task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
                guard let self = self else { return }
                if let result = result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.stopListening()
                }
            }
        } catch {
            errorMessage = "No se pudo iniciar el micrófono: \(error.localizedDescription)"
            stopListening()
        }
    }

    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
        audioLevel = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Cheap RMS-based level from the raw buffer, normalized to roughly
    /// 0...1 with a fixed gain — good enough for a visual meter, not for
    /// anything that needs calibrated dB.
    private func updateAudioLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let samples = channelData[0]
        var sum: Float = 0
        for i in 0..<frameCount {
            sum += samples[i] * samples[i]
        }
        let rms = sqrt(sum / Float(frameCount))
        let level = min(1, rms * 12) // empirical gain so normal speech reaches ~0.5-1.0
        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = level
        }
    }
}
