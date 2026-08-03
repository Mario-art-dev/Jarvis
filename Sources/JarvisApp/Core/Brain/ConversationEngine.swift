import Foundation
import Combine

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
    private var pendingImagePrompt: String?

    private let config: AppConfig
    private let toolRegistry = ToolRegistry()
    private let audioPlayer = AudioPlayer()
    private lazy var serverClient = JarvisServerClient(toolRegistry: toolRegistry)

    init(config: AppConfig) {
        self.config = config
    }

    /// Spoken as soon as the app opens — a fixed line, not routed through
    /// the server, so it works instantly even before the server/login is
    /// ready and doesn't cost a Claude turn just to say hello.
    func greet() async {
        let greeting = "Buenas, señor Gimeno. ¿En qué puedo ayudarle?"
        transcript.append(TranscriptEntry(speaker: "Jarvis", text: greeting))
        await speak(greeting)
    }

    func handleUserUtterance(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        transcript.append(TranscriptEntry(speaker: "Tú", text: text))

        if containsImageTrigger(text) {
            pendingImagePrompt = text
            showImageSourceMenu = true
            return
        }

        let wantsWrittenAnswer = containsWriteTrigger(text)

        state = .thinking
        do {
            let finalText = try await serverClient.ask(text, config: config)
            transcript.append(TranscriptEntry(speaker: "Jarvis", text: finalText))
            if wantsWrittenAnswer {
                writtenResponse = finalText
                state = .idle
            } else {
                await speak(finalText)
            }
        } catch {
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
        do {
            let finalText = try await serverClient.ask(text, images: attachments, config: config)
            transcript.append(TranscriptEntry(speaker: "Jarvis", text: finalText))
            await speak(finalText)
        } catch {
            lastError = error.localizedDescription
            state = .idle
        }
    }

    func cancelImageRequest() {
        pendingImagePrompt = nil
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

    private func speak(_ text: String) async {
        state = .speaking
        do {
            let elevenLabs = ElevenLabsClient(apiKey: config.elevenLabsAPIKey, voiceID: config.elevenLabsVoiceID)
            let audioData = try await elevenLabs.synthesizeSpeech(text: text)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                audioPlayer.play(data: audioData) {
                    continuation.resume()
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
        state = .idle
    }
}
