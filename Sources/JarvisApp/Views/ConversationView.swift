import SwiftUI

struct ConversationView: View {
    @StateObject private var config = AppConfig()
    @StateObject private var engine: ConversationEngine
    /// Both live inside `engine`, not owned here — bound as ObservedObject
    /// purely so this view redraws when their own @Published properties
    /// change (transcript, audioLevel...).
    @ObservedObject private var speech: SpeechRecognizer
    @ObservedObject private var audioPlayer: AudioPlayer
    @State private var showSettings = false
    @State private var hasGreeted = false
    @State private var activeImageSource: ImageSource?

    private enum ImageSource: String, Identifiable {
        case library, camera, file
        var id: String { rawValue }
    }

    @Environment(\.scenePhase) private var scenePhase

    /// How long the transcript must sit unchanged before we treat it as
    /// "the user finished talking" and send it off — continuous listening
    /// has no button press to mark the end of an utterance, so silence is
    /// the only signal available.
    private let silenceThreshold: TimeInterval = 1.3
    private let silenceCheckTimer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    /// When `engine.state` last changed — drives the watchdog below. A
    /// handful of distinct, hard-to-fully-reproduce-remotely bugs have each
    /// left Jarvis stuck on a non-idle state for good (audio session
    /// interruptions, a recognizer that stays unavailable longer than
    /// expected, network calls with no clean way to detect they've gone
    /// stale from the UI side...). Rather than keep chasing each one
    /// individually, this is a blanket safety net: whatever the cause, don't
    /// stay stuck for more than a bounded time.
    @State private var stateEnteredAt = Date()

    init() {
        let sharedConfig = AppConfig()
        _config = StateObject(wrappedValue: sharedConfig)
        let sharedEngine = ConversationEngine(config: sharedConfig)
        _engine = StateObject(wrappedValue: sharedEngine)
        _speech = ObservedObject(wrappedValue: sharedEngine.speech)
        _audioPlayer = ObservedObject(wrappedValue: sharedEngine.audioPlayer)
    }

    var body: some View {
        ZStack {
            HUDView(
                state: engine.state,
                audioLevel: engine.state == .speaking ? audioPlayer.audioLevel : speech.audioLevel,
                liveTranscript: engine.state == .listening ? speech.transcript : ""
            )

            VStack {
                HStack {
                    Spacer()
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(.white.opacity(0.8))
                            .padding()
                    }
                }
                Spacer()
                if engine.state == .listening {
                    muteButton
                        .padding(.bottom, 36)
                        .transition(.opacity.combined(with: .scale))
                } else if isPaused {
                    resumeButton
                        .padding(.bottom, 36)
                        .transition(.opacity.combined(with: .scale))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: engine.state == .listening)
            .animation(.easeInOut(duration: 0.2), value: isPaused)

            if let written = engine.writtenResponse {
                WrittenResponseView(text: written) {
                    engine.writtenResponse = nil
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: engine.writtenResponse != nil)
        .sheet(isPresented: $showSettings) {
            SettingsView(config: config)
        }
        .confirmationDialog("¿Cómo quieres enviar la foto?", isPresented: $engine.showImageSourceMenu, titleVisibility: .visible) {
            Button("Fototeca") { activeImageSource = .library }
            Button("Cámara") { activeImageSource = .camera }
            Button("Archivo") { activeImageSource = .file }
            Button("Cancelar", role: .cancel) { engine.cancelImageRequest() }
        }
        .sheet(isPresented: $engine.showCameraGlance) {
            CameraCapturePicker(
                onPicked: { attachment in
                    engine.showCameraGlance = false
                    Task { await engine.handlePickedImages([attachment]) }
                },
                onCancel: {
                    engine.showCameraGlance = false
                    engine.cancelImageRequest()
                }
            )
            .ignoresSafeArea()
        }
        .sheet(item: $activeImageSource) { source in
            switch source {
            case .library:
                PhotoLibraryPicker(
                    onPicked: { attachments in
                        activeImageSource = nil
                        Task { await engine.handlePickedImages(attachments) }
                    },
                    onCancel: {
                        activeImageSource = nil
                        engine.cancelImageRequest()
                    }
                )
            case .camera:
                CameraCapturePicker(
                    onPicked: { attachment in
                        activeImageSource = nil
                        Task { await engine.handlePickedImages([attachment]) }
                    },
                    onCancel: {
                        activeImageSource = nil
                        engine.cancelImageRequest()
                    }
                )
                .ignoresSafeArea()
            case .file:
                FileImagePicker(
                    onPicked: { attachments in
                        activeImageSource = nil
                        Task { await engine.handlePickedImages(attachments) }
                    },
                    onCancel: {
                        activeImageSource = nil
                        engine.cancelImageRequest()
                    }
                )
            }
        }
        .onAppear {
            guard !hasGreeted, config.isConfigured else {
                if !config.isConfigured { showSettings = true }
                return
            }
            hasGreeted = true
            Task {
                await engine.greet()
                beginListeningIfIdle()
            }
        }
        .onOpenURL { url in
            switch url.host {
            case "listen":
                // jarvisapp://listen — triggered by the Siri Shortcut / Back
                // Tap so saying "Oye Siri, despierta Jarvis" (or a double
                // Back Tap) opens the app and starts listening in one step.
                beginListeningIfIdle()
            case "notes-callback":
                // The Shortcuts app calling back into us with the result of
                // "Jarvis Crear Nota" / "Jarvis Leer Nota" — see NotesTool.
                NotesShortcutBridge.shared.handleCallback(url: url)
            default:
                break
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                engine.isForeground = true
                // iOS can interrupt/kill the mic's audio session for
                // reasons that never reach our own stop/start calls (a
                // phone call, Siri, another app's audio, the app being
                // suspended outright) — when that happens, speech.isListening
                // stays stuck at true even though nothing is actually
                // running anymore, and beginListeningIfIdle()'s own
                // `!speech.isListening` guard then silently blocks it from
                // ever trying again. This showed up as Jarvis sitting on
                // the idle ring forever after returning from another app,
                // fixed only by force-quitting. Unconditionally stopping
                // first guarantees a clean slate no matter what happened
                // while backgrounded — stopping an already-stopped
                // recognizer is a harmless no-op.
                speech.stopListening()
                // Pick up anything that finished while you were away before
                // re-arming the mic — this is what makes "ask for something
                // long, leave, come back" actually tell you the result
                // instead of silently dropping it. No-ops when there's
                // nothing waiting, so the normal case is unaffected.
                Task {
                    await engine.deliverPendingResultIfAny()
                    beginListeningIfIdle()
                }
            } else {
                engine.isForeground = false
                engine.handleAppBackgrounded()
            }
        }
        .onChange(of: engine.state) { newState in
            stateEnteredAt = Date()
            // Loop back to listening automatically once Jarvis finishes
            // speaking — that's the "no mic button needed" behavior.
            if newState == .idle {
                beginListeningIfIdle()
            }
        }
        .onChange(of: speech.errorMessage) { newValue in
            // beginListeningIfIdle() marks state as .listening right before
            // asking the mic to actually start — if that start silently
            // fails (ej. the speech recognizer being transiently
            // unavailable, see SpeechRecognizer.startListening), state was
            // left stuck on .listening forever with a mic that never
            // actually ran, since nothing else was watching for that.
            // Resetting to .idle here lets the same retry loop above give
            // it another try instead of looking permanently frozen.
            guard newValue != nil, engine.state == .listening else { return }
            engine.state = .idle
        }
        .onReceive(silenceCheckTimer) { _ in
            guard engine.state == .listening, speech.isListening, !speech.transcript.isEmpty else { return }
            guard speech.secondsSinceLastTranscriptChange() >= silenceThreshold else { return }
            finishListeningAndSubmit()
        }
        .onReceive(silenceCheckTimer) { _ in
            // Watchdog: force a full recovery if Jarvis has sat on a
            // non-idle state for too long without progressing — a bound
            // generous enough that it never interrupts something genuinely
            // in progress (.thinking already has its own 90s network
            // watchdog in JarvisServerClient; this is a backstop above
            // that), but short enough that "frozen for minutes until you
            // force-quit" simply can't happen anymore, whatever the cause.
            guard scenePhase == .active, engine.state != .idle else { return }
            let maxDuration: TimeInterval
            switch engine.state {
            case .thinking: maxDuration = 320 // just above JarvisServerClient's own 5-min network watchdog
            case .speaking: maxDuration = 60  // generous for even a long spoken answer
            case .listening: maxDuration = 45 // generous for a long ramble with no pause
            case .idle: maxDuration = .infinity // unreachable, guarded above
            }
            guard Date().timeIntervalSince(stateEnteredAt) > maxDuration else { return }
            speech.stopListening()
            audioPlayer.stop()
            engine.state = .idle
        }
        .alert("Error", isPresented: .constant(engine.lastError != nil)) {
            Button("OK") { engine.lastError = nil }
        } message: {
            Text(engine.lastError ?? "")
        }
    }

    /// Starts the mic automatically whenever Jarvis is free (idle, app in
    /// foreground, configured) — this is what makes listening "always on"
    /// while the app is open, with no tap required.
    private func beginListeningIfIdle() {
        guard config.isConfigured else { return }
        guard !speech.isListening else { return }
        guard engine.state == .idle && scenePhase == .active else { return }

        speech.requestAuthorization { granted in
            guard granted else {
                engine.lastError = "Necesito permiso de micrófono y reconocimiento de voz."
                return
            }
            engine.state = .listening
            speech.startListening()
        }
    }

    /// Only shown while actually listening — tapping it ends the turn right
    /// now instead of waiting for the usual silence detection, for when you
    /// want Jarvis to start thinking immediately (ej. background noise
    /// keeps resetting the silence timer, or you just don't want to wait
    /// out the pause).
    private var muteButton: some View {
        Button {
            guard !speech.transcript.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            finishListeningAndSubmit()
        } label: {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.black)
                .frame(width: 60, height: 60)
                .background(Color.white.opacity(0.9))
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.3), radius: 8)
        }
    }

    /// "Paused": sitting idle with the mic genuinely not running. Normally
    /// unreachable for more than an instant, since going idle immediately
    /// re-arms listening — so if this is true and stays true, something
    /// stopped the loop (a mic that refused to start, a long request the
    /// phone gave up waiting on, the watchdog force-resetting a stuck
    /// state). That's exactly when a manual way back in is worth offering.
    private var isPaused: Bool {
        config.isConfigured
            && engine.state == .idle
            && !speech.isListening
            && engine.writtenResponse == nil
    }

    /// Picks up wherever things were left off: if a long request outlived
    /// the phone's patience, that result is waiting on the server, so check
    /// for it first; otherwise just get the mic going again. Covers both
    /// "it was thinking" and "it was listening" without needing to know
    /// which it was.
    private var resumeButton: some View {
        Button {
            Task {
                await engine.deliverPendingResultIfAny()
                speech.stopListening()
                beginListeningIfIdle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: engine.awaitingLongTask ? "tray.and.arrow.down.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                Text(engine.awaitingLongTask ? "Ver si ya está listo" : "Continuar")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
            }
            .foregroundColor(.black)
            .padding(.horizontal, 24)
            .frame(height: 56)
            .background(Color.white.opacity(0.9))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.3), radius: 8)
        }
    }

    private func finishListeningAndSubmit() {
        speech.stopListening()
        let text = speech.transcript
        Task {
            await engine.handleUserUtterance(text)
        }
    }
}

#Preview {
    ConversationView()
}
