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

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
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
        guard let recognizer = recognizer, recognizer.isAvailable else {
            errorMessage = "El reconocimiento de voz no está disponible ahora mismo."
            return
        }

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
            }

            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
