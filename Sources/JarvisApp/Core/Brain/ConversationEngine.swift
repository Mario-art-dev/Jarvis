import Foundation
import Combine

struct TranscriptEntry: Identifiable {
    let id = UUID()
    let speaker: String // "Tú" | "Jarvis"
    let text: String
}

/// Orchestrates one full turn: user text -> Claude (with tools) -> execute
/// any tool calls -> feed results back to Claude -> final spoken answer.
/// This is the agentic loop; Claude can chain several tool calls in a row
/// before producing the text that actually gets spoken.
@MainActor
final class ConversationEngine: ObservableObject {
    @Published var transcript: [TranscriptEntry] = []
    @Published var state: JarvisState = .idle
    @Published var lastError: String?

    private let config: AppConfig
    private let toolRegistry = ToolRegistry()
    private let audioPlayer = AudioPlayer()
    private var history: [ClaudeMessage] = []

    private let systemPrompt = """
    Eres Jarvis, el asistente personal de voz de Mario. Respondes siempre en español, \
    de forma breve y natural porque tus respuestas se van a leer en voz alta. \
    Usa las herramientas disponibles cuando la petición del usuario lo requiera \
    (buscar en internet, abrir apps, gestionar calendario, recordatorios, contactos o fotos). \
    Si no tienes una herramienta para algo, dilo con claridad en vez de inventar que lo hiciste.
    """

    init(config: AppConfig) {
        self.config = config
    }

    func handleUserUtterance(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        transcript.append(TranscriptEntry(speaker: "Tú", text: text))
        history.append(ClaudeMessage(role: "user", content: [["type": "text", "text": text]]))

        state = .thinking
        do {
            let finalText = try await runAgentLoop()
            transcript.append(TranscriptEntry(speaker: "Jarvis", text: finalText))
            await speak(finalText)
        } catch {
            lastError = error.localizedDescription
            state = .idle
        }
    }

    /// Runs Claude turns until it stops requesting tools, executing each
    /// tool call locally and feeding results back as a "user" tool_result turn.
    private func runAgentLoop() async throws -> String {
        let client = ClaudeClient(apiKey: config.anthropicAPIKey)
        var guardCounter = 0

        while guardCounter < 6 {
            guardCounter += 1
            let turn = try await client.sendTurn(
                systemPrompt: systemPrompt,
                messages: history,
                tools: toolRegistry.claudeToolDefinitions
            )

            history.append(ClaudeMessage(role: "assistant", content: turn.rawAssistantContent))

            if turn.toolUses.isEmpty {
                return turn.assistantText.isEmpty ? "Hecho." : turn.assistantText
            }

            var resultBlocks: [[String: Any]] = []
            for use in turn.toolUses {
                let resultText: String
                do {
                    if let tool = toolRegistry.tool(named: use.name) {
                        resultText = try await tool.execute(input: use.input)
                    } else {
                        resultText = "Herramienta desconocida: \(use.name)"
                    }
                } catch {
                    resultText = "Error ejecutando \(use.name): \(error.localizedDescription)"
                }
                resultBlocks.append([
                    "type": "tool_result",
                    "tool_use_id": use.id,
                    "content": resultText
                ])
            }
            history.append(ClaudeMessage(role: "user", content: resultBlocks))
        }

        return "He tardado demasiado encadenando acciones, ¿puedes reformular la petición?"
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
