import Foundation
import Combine

struct TranscriptEntry: Identifiable {
    let id = UUID()
    let speaker: String // "Tú" | "Jarvis"
    let text: String
}

/// Orchestrates one full turn: user text -> Jarvis server (Claude Code,
/// authenticated with your subscription) -> tool calls executed locally on
/// the phone -> final spoken answer via ElevenLabs.
@MainActor
final class ConversationEngine: ObservableObject {
    @Published var transcript: [TranscriptEntry] = []
    @Published var state: JarvisState = .idle
    @Published var lastError: String?

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

        state = .thinking
        do {
            let finalText = try await serverClient.ask(text, config: config)
            transcript.append(TranscriptEntry(speaker: "Jarvis", text: finalText))
            await speak(finalText)
        } catch {
            lastError = error.localizedDescription
            state = .idle
        }
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
