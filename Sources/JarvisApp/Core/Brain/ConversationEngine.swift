import Foundation
import Combine
import UIKit
import UserNotifications

struct TranscriptEntry: Identifiable {
    let id = UUID()
    let speaker: String // "Tú" | "Jarvis"
    let text: String
}

/// Orchestrates one full turn: user text -> Jarvis server (Claude Code,
/// authenticated with your subscription) -> tool calls executed locally on
/// the phone -> final spoken answer via ElevenLabs (or written on screen if
/// the user said the "escríbeme" trigger word).
@MainActor
final class ConversationEngine: ObservableObject {
    @Published var transcript: [TranscriptEntry] = []
    @Published var state: JarvisState = .idle
    @Published var lastError: String?
    /// Non-nil while a written (not spoken) answer is on screen — set when
    /// the user's utterance contained "escríbeme". The view shows this as
    /// an overlay with a close button instead of playing audio.
    @Published var writtenResponse: String?
    /// Set when the user's utterance asked to send a photo — the view shows
    /// the Fototeca/Cámara/Archivo menu while this holds the request text,
    /// which gets sent together with whatever image the user picks.
    @Published var showImageSourceMenu = false
    /// Set when the user asked Jarvis to look at something right now (ej.
    /// "mira esto", "¿qué ves?") — the view jumps straight to the camera,
    /// skipping the source picker, so it feels like a glance instead of a
    /// deliberate "attach a file" flow.
    @Published var showCameraGlance = false
    /// Kept in sync by the view from scenePhase — lets a turn that finishes
    /// while the user has stepped away notify instead of trying to speak
    /// into a screen nobody's looking at. See handleUserUtterance.
    @Published var isForeground = true
    private var pendingImagePrompt: String?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// Owned here (not by the view) so this class can also run it while
    /// Jarvis is speaking, to detect the user barging in — see
    /// startInterruptWatch(). The view still binds to it directly for the
    /// mic button / silence-detection timer.
    let speech = SpeechRecognizer()
    let audioPlayer = AudioPlayer()

    private let config: AppConfig
    private let toolRegistry = ToolRegistry()
    private lazy var serverClient = JarvisServerClient(toolRegistry: toolRegistry)

    private var interruptWatch: AnyCancellable?
    private var wasInterrupted = false

    init(config: AppConfig) {
        self.config = config
    }

    /// Spoken as soon as the app opens — a fixed line, not routed through
    /// the server, so it works instantly even before the server/login is
    /// ready and doesn't cost a Claude turn just to say hello.
    func greet() async {
        // Fire-and-forget: has to happen while the app is in the foreground
        // to actually show the system prompt, so ask early rather than the
        // first time a background turn tries to use it.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        let greeting = "Buenas, señor. ¿En qué puedo ayudarle?"
        transcript.append(TranscriptEntry(speaker: "Jarvis", text: greeting))
        await speak(greeting)
        // If the user already jumped in over the greeting (state is
        // .listening, not .idle — see speak()'s interrupt handling), don't
        // barge in on top of THAT with a second announcement.
        guard state == .idle else { return }

        // If something you asked before closing the app finished running
        // in the meantime (see server/src/backgroundJobs.ts), deliver it
        // now instead of it sitting there silently done.
        if let pendingResult = await serverClient.checkPendingResult(config: config),
           !pendingResult.trimmingCharacters(in: .whitespaces).isEmpty {
            let announcement = "Por cierto, terminé lo que me pidió antes: \(pendingResult)"
            transcript.append(TranscriptEntry(speaker: "Jarvis", text: announcement))
            await speak(announcement)
        }
    }

    func handleUserUtterance(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        transcript.append(TranscriptEntry(speaker: "Tú", text: text))

        if containsVisionGlanceTrigger(text) {
            pendingImagePrompt = text
            showCameraGlance = true
            return
        }

        if containsImageTrigger(text) {
            pendingImagePrompt = text
            showImageSourceMenu = true
            return
        }

        let wantsWrittenAnswer = containsWriteTrigger(text)

        state = .thinking
        beginBackgroundTask()
        do {
            let finalText = try await serverClient.ask(text, config: config)
            endBackgroundTask()
            transcript.append(TranscriptEntry(speaker: "Jarvis", text: finalText))
            if !isForeground {
                // Stepped away while this was running — can't speak into a
                // screen nobody's looking at, so this is the notification
                // from the "impress the family" list: "tu receta está
                // lista" instead of silence.
                notifyCompletion(finalText)
                if wantsWrittenAnswer { writtenResponse = finalText }
                state = .idle
            } else if wantsWrittenAnswer {
                writtenResponse = finalText
                state = .idle
            } else {
                await speak(finalText)
            }
        } catch {
            endBackgroundTask()
            lastError = error.localizedDescription
            state = .idle
        }
    }

    /// Called once the user picked a source and Jarvis has the image(s) in
    /// hand. `attachments` empty means they cancelled the picker.
    func handlePickedImages(_ attachments: [ImageAttachment]) async {
        guard let text = pendingImagePrompt else { return }
        pendingImagePrompt = nil
        guard !attachments.isEmpty else { return }

        state = .thinking
        beginBackgroundTask()
        do {
            let finalText = try await serverClient.ask(text, images: attachments, config: config)
            endBackgroundTask()
            transcript.append(TranscriptEntry(speaker: "Jarvis", text: finalText))
            if !isForeground {
                notifyCompletion(finalText)
                state = .idle
            } else {
                await speak(finalText)
            }
        } catch {
            endBackgroundTask()
            lastError = error.localizedDescription
            state = .idle
        }
    }

    func cancelImageRequest() {
        pendingImagePrompt = nil
    }

    /// Called when the app leaves the foreground (backgrounded, another app
    /// opened, phone locked). `state` doesn't reset on its own when that
    /// happens, so without this it can get stuck (see the two bugs below),
    /// blocking `beginListeningIfIdle()`'s `state == .idle` guard forever —
    /// which is what made Jarvis look frozen until force-quit and reopened.
    ///
    /// Order matters here: mic and speaker now share one audio session
    /// (.playAndRecord, so the mic can listen for "calla" while Jarvis
    /// talks — see startInterruptWatch). Killing the mic first
    /// (speech.stopListening deactivates the *shared* session) while the
    /// player is still mid-playback yanks the session out from under
    /// AVAudioPlayer without going through its own stop() — so it never
    /// fires its completion callback, and speak() hangs forever awaiting it.
    /// That was the second freeze bug. Stopping the player FIRST (its own
    /// stop() always fires the completion, see AudioPlayer.stop) lets
    /// speak() finish normally and stop the mic itself, in the right order.
    func handleAppBackgrounded() {
        interruptWatch?.cancel()
        interruptWatch = nil
        switch state {
        case .listening:
            speech.stopListening()
            state = .idle
        case .speaking:
            audioPlayer.stop()
        case .idle, .thinking:
            break
        }
    }

    /// Accent/case-insensitive match so "escríbeme", "Escribeme", etc. all
    /// trigger written mode regardless of how Speech transcribed it.
    private func containsWriteTrigger(_ text: String) -> Bool {
        let normalized = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return normalized.contains("escribeme")
    }

    /// Detects phrases like "te voy a enviar una foto" / "te voy a mandar
    /// una foto" — needs both a photo word and a send word so it doesn't
    /// fire on unrelated sentences that happen to mention a photo.
    private func containsImageTrigger(_ text: String) -> Bool {
        let normalized = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let mentionsPhoto = normalized.contains("foto") || normalized.contains("imagen") || normalized.contains("archivo")
        let mentionsSend = normalized.contains("enviar") || normalized.contains("mandar") || normalized.contains("envio") || normalized.contains("mando")
        return mentionsPhoto && mentionsSend
    }

    /// Detects "look at this" phrases ("mira esto", "¿qué ves?", "echa un
    /// vistazo", "reconoces esto/a quién es") — deliberately specific fixed
    /// phrases rather than a loose keyword like "mira" alone, since that's a
    /// common filler word in casual Spanish and continuous listening would
    /// otherwise open the camera constantly by accident.
    private func containsVisionGlanceTrigger(_ text: String) -> Bool {
        let normalized = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let phrases = [
            "mira esto", "mirame esto", "que ves", "que es esto",
            "echa un vistazo", "echale un vistazo", "hechale un vistazo",
            "reconoces esto", "reconoces a", "quien soy", "sabes quien soy",
            "abre la camara", "abre camara", "abre camaras"
        ]
        return phrases.contains { normalized.contains($0) }
    }

    private func speak(_ text: String) async {
        state = .speaking
        wasInterrupted = false
        do {
            let elevenLabs = ElevenLabsClient(apiKey: config.elevenLabsAPIKey, voiceID: config.elevenLabsVoiceID)
            let audioData = try await elevenLabs.synthesizeSpeech(text: text)

            startInterruptWatch()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                audioPlayer.play(data: audioData) {
                    continuation.resume()
                }
            }
            stopInterruptWatch()
        } catch {
            lastError = error.localizedDescription
            stopInterruptWatch()
        }

        if wasInterrupted {
            wasInterrupted = false
            // Don't cut the user off at whatever they'd said the instant
            // the interruption was detected — hand off to the normal
            // listening/silence-detection flow instead, on the SAME
            // still-running mic session (so the words they interrupted
            // with stay in speech.transcript instead of being reset), and
            // let them keep talking until they actually pause.
            state = .listening
            return
        }
        // Not interrupted: stop the listening session that was only running
        // for interrupt-detection, so beginListeningIfIdle() starts a clean
        // one for the user's next utterance instead of reusing a transcript
        // buffer full of Jarvis's own echoed speech.
        speech.stopListening()
        state = .idle
    }

    /// While Jarvis talks, the mic stays on listening for one specific word
    /// — "calla" — instead of trying to interrupt on anything that sounds
    /// like the user talking. An early version tried to detect ANY speech
    /// that didn't match what Jarvis was currently saying, to tell a real
    /// interruption apart from the mic just picking up his own voice
    /// through the speaker — but that echo is noisy enough (no hardware
    /// echo cancellation here) that it kept misfiring on Jarvis's own
    /// voice, cutting him off mid-sentence for no reason. A single fixed
    /// keyword sidesteps that entirely: no echo is going to transcribe as
    /// "calla" by accident.
    private func startInterruptWatch() {
        speech.requestAuthorization { [weak self] granted in
            guard let self, granted, !self.speech.isListening else { return }
            self.speech.startListening()
        }
        interruptWatch = speech.$transcript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] heard in
                self?.evaluatePossibleInterruption(heard)
            }
    }

    private func stopInterruptWatch() {
        interruptWatch?.cancel()
        interruptWatch = nil
    }

    private func evaluatePossibleInterruption(_ heard: String) {
        guard state == .speaking, !wasInterrupted else { return }
        guard normalizeForComparison(heard).contains("calla") else { return }

        wasInterrupted = true
        audioPlayer.stop()
    }

    /// Strips accents/case/punctuation so "cállate", "¡calla!", "Calla." etc
    /// all match regardless of exactly how it's said or transcribed.
    private func normalizeForComparison(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let keep = CharacterSet.alphanumerics.union(.whitespaces)
        let scrubbed = String(folded.unicodeScalars.map { keep.contains($0) ? Character($0) : " " })
        return scrubbed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Buys extra run time from iOS for a turn that's mid-flight when the
    /// user backgrounds the app (steps away without force-quitting) —
    /// without this, standard background suspension would cut the network
    /// request off within seconds. Apple guarantees at least ~30s; often
    /// more, but never indefinitely — there's no way around that short of a
    /// paid Developer account's remote push, which this project doesn't
    /// have. If a turn does outlast the window, the connection drops and
    /// server/src/backgroundJobs.ts's pending-result fallback (see
    /// ConversationEngine.greet) delivers it next time the app reopens
    /// instead of losing it.
    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "JarvisTurn") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    /// Delivered only when a turn finishes while the app isn't in the
    /// foreground (see the `!isForeground` branches above) — the one case
    /// where speaking the answer out loud wouldn't reach anyone.
    private func notifyCompletion(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = "Jarvis"
        content.body = text.count > 180 ? String(text.prefix(180)) + "…" : text
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
