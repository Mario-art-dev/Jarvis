import SwiftUI

struct ConversationView: View {
    @StateObject private var config = AppConfig()
    @StateObject private var speech = SpeechRecognizer()
    @StateObject private var engine: ConversationEngine
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

    init() {
        let sharedConfig = AppConfig()
        _config = StateObject(wrappedValue: sharedConfig)
        _engine = StateObject(wrappedValue: ConversationEngine(config: sharedConfig))
    }

    var body: some View {
        ZStack {
            HUDView(state: engine.state)

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
            }

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
                beginListeningIfIdle()
            } else {
                speech.stopListening()
                engine.handleAppBackgrounded()
            }
        }
        .onChange(of: engine.state) { newState in
            // Loop back to listening automatically once Jarvis finishes
            // speaking — that's the "no mic button needed" behavior.
            if newState == .idle {
                beginListeningIfIdle()
            }
        }
        .onReceive(silenceCheckTimer) { _ in
            guard speech.isListening, !speech.transcript.isEmpty else { return }
            guard speech.secondsSinceLastTranscriptChange() >= silenceThreshold else { return }
            finishListeningAndSubmit()
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
