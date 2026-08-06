import Foundation
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
    /// Arms/disarms WakeWordListener on every transition: idle hands the mic
    /// to it (only actually starts listening while backgrounded — see
    /// rearmWakeWordIfNeeded), anything else takes the mic away from it
    /// immediately, since exactly one of {WakeWordListener, SpeechRecognizer,
    /// AudioPlayer, SystemVoice} may own the audio session at a time.
    @Published var state: JarvisState = .idle {
        didSet {
            guard state != oldValue else { return }
            if state == .idle {
                rearmWakeWordIfNeeded()
            } else {
                wakeWordListener.stop()
            }
        }
    }
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
    /// True between "a request took so long the phone gave up waiting" and
    /// "its result was finally delivered". The work itself continues on the
    /// server regardless — this just lets the UI offer to go check on it
    /// (see ConversationView's resume button) instead of pretending nothing
    /// is outstanding.
    @Published var awaitingLongTask = false
    /// Mic switched off on purpose, like mute on a call — Jarvis stops
    /// hearing you entirely until you switch it back on. Distinct from
    /// merely not listening right now (which is transient and
    /// self-correcting): this suppresses the auto-restart, so nothing
    /// re-arms the mic behind your back.
    @Published private(set) var isMuted = false
    private var pendingImagePrompt: String?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// An answer that arrived while you were out of the app and was meant
    /// to be spoken. It gets a notification at the time, but speaking it
    /// then would be talking to an empty room — so it waits here and is
    /// spoken the moment you come back (see deliverWhatYouMissed).
    ///
    /// Persisted rather than held in memory because iOS may kill the app
    /// outright while backgrounded, and the server-side fallback doesn't
    /// cover this case: from the server's point of view the answer was
    /// delivered successfully (the phone was still alive to receive it),
    /// so it doesn't keep a copy.
    private var unspokenAnswer: String? {
        get { UserDefaults.standard.string(forKey: Self.unspokenAnswerKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: Self.unspokenAnswerKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.unspokenAnswerKey)
            }
        }
    }
    private static let unspokenAnswerKey = "com.mariomontesinos.jarvis.unspokenAnswer"

    /// Owned here (not by the view) purely so the view can bind to it for
    /// the silence-detection timer and live HUD level/transcript.
    let speech = SpeechRecognizer()
    let audioPlayer = AudioPlayer()
    /// Only ever active while backgrounded with a request in flight — see
    /// BackgroundKeepAlive for why, and why it can't collide with the mic
    /// or with spoken replies.
    private let keepAlive = BackgroundKeepAlive()
    /// Its own recognizer, entirely separate from `speech` — see
    /// InterruptListener for why that isolation matters.
    private let interruptListener = InterruptListener()
    /// "Jarvis escucha" — its own recognizer too, for the same reason. See
    /// WakeWordListener for why it only matters while backgrounded.
    private let wakeWordListener = WakeWordListener()
    /// Fallback voice for when ElevenLabs can't synthesise (see speak).
    private let systemVoice = SystemVoice()
    private var hasReportedVoiceFallback = false

    private let config: AppConfig
    private let toolRegistry = ToolRegistry()
    private lazy var serverClient = JarvisServerClient(toolRegistry: toolRegistry)

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
        await deliverWhatYouMissed()
    }

    /// Everything that finished while you weren't looking, delivered on
    /// return: first an answer that arrived and was notified but never
    /// actually spoken (you weren't there to hear it), then anything the
    /// server finished after the phone had already dropped off entirely.
    ///
    /// Called on app launch and on every foreground return, so "ask for
    /// something, walk away, come back" always ends with Jarvis telling
    /// you the answer — whether it was meant to be spoken or written.
    func deliverWhatYouMissed() async {
        guard config.isConfigured, state == .idle else { return }

        // Clear only once it's actually about to be delivered, so bailing
        // out above can't silently drop the one copy of it we have.
        if let unspoken = unspokenAnswer {
            unspokenAnswer = nil
            await speak(unspoken)
        }
        await deliverPendingResultIfAny()
    }

    /// Asks the server whether a turn finished while this phone wasn't
    /// connected to receive it (see server/src/backgroundJobs.ts) and, if
    /// so, delivers it now.
    ///
    /// Called both on app launch (from greet) and every time the app
    /// returns to the foreground — that second case is what makes "ask for
    /// something long, leave the app, come back" actually work. It used to
    /// run only at launch, so returning to an app iOS had merely suspended
    /// (rather than killed) meant the finished answer just sat on the
    /// server unmentioned.
    ///
    /// Safe to call repeatedly: the server hands each result out at most
    /// once, and this no-ops unless Jarvis is idle.
    func deliverPendingResultIfAny() async {
        guard state == .idle, config.isConfigured else { return }
        guard let pendingResult = await serverClient.checkPendingResult(config: config),
              !pendingResult.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        awaitingLongTask = false
        let announcement = "Ya tengo lo que me pidió: \(pendingResult)"
        transcript.append(TranscriptEntry(speaker: "Jarvis", text: announcement))
        // A long answer (ej. "escríbeme un libro") is unbearable read aloud
        // and gets truncated by the notification anyway — put those on
        // screen, speak only the short ones.
        if pendingResult.count > 400 {
            writtenResponse = announcement
        } else {
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
        // Normally handleAppBackgrounded starts this the moment you step
        // away mid-turn. A turn that *starts* while already backgrounded —
        // ej. one triggered by "Jarvis escucha" — never passes through
        // there, so it needs the same extension started explicitly here or
        // a long answer would get cut off by the ~30s background-task grace
        // period alone.
        if !isForeground { keepAlive.start() }
        do {
            let finalText = try await serverClient.ask(text, config: config)
            endBackgroundTask()
            keepAlive.stop()
            awaitingLongTask = false
            transcript.append(TranscriptEntry(speaker: "Jarvis", text: finalText))
            if !isForeground {
                // Stepped away while this was running: notify now, and hold
                // the answer so it's actually delivered when you come back
                // — a written one stays on screen, a spoken one gets spoken
                // then (see deliverWhatYouMissed) instead of being silently
                // dropped for having finished while nobody was listening.
                notifyCompletion(finalText)
                if wantsWrittenAnswer {
                    writtenResponse = finalText
                } else {
                    unspokenAnswer = finalText
                }
                state = .idle
            } else if wantsWrittenAnswer {
                writtenResponse = finalText
                state = .idle
            } else {
                await speak(finalText)
            }
        } catch {
            endBackgroundTask()
            handleTurnFailure(error)
        }
    }

    /// A timeout isn't really a failure here — the server keeps working on
    /// it and the answer gets picked up later (see
    /// deliverPendingResultIfAny), so it gets a reassuring message and a
    /// flag the UI can act on, rather than the red error alert every other
    /// failure deserves.
    private func handleTurnFailure(_ error: Error) {
        keepAlive.stop()
        if let serverError = error as? ServerError, case .timedOut = serverError {
            awaitingLongTask = true
            let note = "Esto está llevando un rato. Sigo trabajando en ello — te aviso en cuanto lo tenga."
            transcript.append(TranscriptEntry(speaker: "Jarvis", text: note))
        } else {
            lastError = error.localizedDescription
        }
        state = .idle
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
            keepAlive.stop()
            awaitingLongTask = false
            transcript.append(TranscriptEntry(speaker: "Jarvis", text: finalText))
            if !isForeground {
                notifyCompletion(finalText)
                unspokenAnswer = finalText
                state = .idle
            } else {
                await speak(finalText)
            }
        } catch {
            endBackgroundTask()
            handleTurnFailure(error)
        }
    }

    func cancelImageRequest() {
        pendingImagePrompt = nil
    }

    /// Mic on/off, like the mute button on a call. Muting cuts the mic
    /// immediately even mid-sentence; it deliberately does NOT stop Jarvis
    /// talking, same as muting yourself doesn't mute the other person.
    /// Unmuting is picked up by the caller, which re-arms listening.
    func toggleMute() {
        isMuted.toggle()
        guard isMuted else { return }
        speech.stopListening()
        // Muting also stops "Jarvis calla" and "Jarvis escucha" — mic off
        // means mic off, whatever it was being used for.
        interruptListener.stop()
        wakeWordListener.stop()
        if state == .listening { state = .idle }
    }

    /// Called when the app leaves the foreground (backgrounded, another app
    /// opened, phone locked). The mic/speaker don't reset `state` on their
    /// own, so without this it can get stuck at `.listening` or
    /// `.speaking`, blocking `beginListeningIfIdle()`'s `state == .idle`
    /// guard forever — which is what made Jarvis look frozen until
    /// force-quit and reopened. `.thinking` (an in-flight server turn) is
    /// deliberately left alone here — see JarvisServerClient's timeout for
    /// how that case now resolves instead of hanging forever too.
    func handleAppBackgrounded() {
        isForeground = false
        switch state {
        case .listening:
            speech.stopListening()
            state = .idle
        case .speaking:
            // Fires the pending completion too (see AudioPlayer.stop), so
            // this unblocks speak()'s continuation and it sets state =
            // .idle itself right after.
            interruptListener.stop()
            audioPlayer.stop()
            systemVoice.stop()
        case .thinking:
            // A request is in flight and you've walked away — keep the app
            // alive so it can actually notify you the moment the answer
            // lands, instead of being suspended and only telling you next
            // time you open it. See BackgroundKeepAlive.
            keepAlive.start()
        case .idle:
            // Nothing else owns the mic right now — this is exactly when
            // "Jarvis escucha" should start listening for you, since
            // foreground's continuous listening (which would otherwise make
            // this redundant) doesn't apply while backgrounded.
            rearmWakeWordIfNeeded()
        }
    }

    /// Counterpart to handleAppBackgrounded — drops the keep-alive and the
    /// wake word as soon as neither is needed, so nothing holds audio (or
    /// battery) while you're actually looking at the app. Foreground's own
    /// continuous listening (see ConversationView.beginListeningIfIdle)
    /// takes over instead.
    func handleAppForegrounded() {
        isForeground = true
        keepAlive.stop()
        wakeWordListener.stop()
    }

    /// Starts "Jarvis escucha" listening, but only when it would actually be
    /// useful: nothing else is using the mic (`state == .idle`), the app is
    /// backgrounded (foreground already listens continuously with no wake
    /// word needed — see beginListeningIfIdle), the mic hasn't been muted on
    /// purpose, and there's somewhere to actually send a resulting turn.
    /// Safe to call whenever any of those might have changed; a no-op
    /// otherwise.
    private func rearmWakeWordIfNeeded() {
        guard !isForeground, state == .idle, !isMuted, config.isConfigured else {
            wakeWordListener.stop()
            return
        }
        wakeWordListener.start { [weak self] in
            self?.handleWakeWordTriggered()
        }
    }

    /// "Jarvis escucha" was heard while backgrounded — hand off to the same
    /// mic normal foreground listening uses, so whatever you say next is
    /// captured and submitted exactly like any other turn. If that turn
    /// finishes while you're still away, handleUserUtterance's existing
    /// `!isForeground` branch already notifies and queues the answer for
    /// when you return — no separate handling needed here for that part.
    private func handleWakeWordTriggered() {
        guard state == .idle, !isMuted, config.isConfigured else { return }
        state = .listening // didSet above stops wakeWordListener
        speech.requestAuthorization { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.state = .idle
                return
            }
            self.speech.startListening()
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
        // Ajustes → "Usar solo la voz del iPhone": skip the Mac and
        // ElevenLabs entirely, so this never depends on the server being
        // reachable or on any account's quota.
        if config.preferPhoneVoice {
            await systemVoice.speak(text)
            state = .idle
            return
        }
        do {
            // The Mac's own voice first: free, unlimited, and no quota to run
            // out of. Returns nil if the Mac has no Spanish voice or the
            // server is unreachable, so this costs one quick local round trip
            // and then carries on to ElevenLabs.
            let audioData: Data
            if let localAudio = await serverClient.synthesize(text, config: config) {
                audioData = localAudio
            } else {
                let elevenLabs = ElevenLabsClient(apiKey: config.elevenLabsAPIKey, voiceID: config.elevenLabsVoiceID)
                audioData = try await elevenLabs.synthesizeSpeech(text: text)
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // play() configures the audio session for simultaneous
                // record+playback, so the listener below has to start after
                // it, and only ever attaches a tap to that session.
                audioPlayer.play(data: audioData) {
                    continuation.resume()
                }
                // Not while muted: if you've switched the mic off, it stays
                // off — no listening of any kind behind your back.
                if !isMuted {
                    // Passing the reply's own text lets a bare "calla" work
                    // for it — see InterruptListener.shortPhrase.
                    interruptListener.start(whileSaying: text) { [weak self] in
                        self?.audioPlayer.stop()
                    }
                }
            }
            interruptListener.stop()
        } catch {
            interruptListener.stop()
            // Never go mute over this. ElevenLabs failing (nearly always a
            // used-up monthly quota) used to leave Jarvis silent with only a
            // raw API error on screen, which looks exactly like the whole app
            // being broken — every tool had actually run, there was just
            // nothing to say so out loud.
            reportVoiceFallbackOnce(error)
            await systemVoice.speak(text)
        }
        state = .idle
    }

    /// Surfaces *why* the voice changed, but only the first time per launch:
    /// the reason is worth knowing once, and worth not being nagged about on
    /// every single reply for the rest of the month.
    private func reportVoiceFallbackOnce(_ error: Error) {
        guard !hasReportedVoiceFallback else { return }
        hasReportedVoiceFallback = true

        let detail = error.localizedDescription
        if detail.contains("quota_exceeded") || detail.contains("quota") {
            lastError = "Se han agotado los créditos mensuales de tu cuenta de ElevenLabs, así que Jarvis seguirá hablando con la voz del iPhone (suena peor, pero es gratis e ilimitada). Se renuevan cada mes; si quieres la voz buena antes, hay que ampliar el plan en elevenlabs.io."
        } else {
            lastError = "No he podido usar la voz de ElevenLabs (\(detail)). Sigo con la voz del iPhone mientras tanto."
        }
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
    /// where speaking the answer out loud wouldn't reach anyone. Leads with
    /// "ya está listo" rather than just dumping the answer, since a long
    /// one gets truncated here anyway and the point is to tell you it's
    /// worth coming back in.
    private func notifyCompletion(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = "Jarvis ya tiene tu respuesta"
        let preview = text.count > 160 ? String(text.prefix(160)) + "…" : text
        content.body = "\(preview)\n\nAbre Jarvis para verlo entero."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
