import Foundation

enum ClaudeError: Error, LocalizedError {
    case missingAPIKey
    case requestFailed(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Falta la API key de Anthropic. Configúrala en Ajustes."
        case .requestFailed(let message): return "Claude: \(message)"
        case .malformedResponse: return "Respuesta inesperada de Claude."
        }
    }
}

/// One entry in the running conversation, mirroring the Anthropic Messages
/// API "role" + "content" shape (content can be plain text or tool blocks).
struct ClaudeMessage {
    let role: String // "user" | "assistant"
    let content: [[String: Any]]
}

/// A tool_use block Claude asked to execute, plus the text it said alongside it.
struct ClaudeTurn {
    let assistantText: String
    let toolUses: [(id: String, name: String, input: [String: Any])]
    let rawAssistantContent: [[String: Any]]
    let stopReason: String
}

/// Minimal Anthropic Messages API client with tool-use support, used as
/// Jarvis's decision-making brain: given the user's spoken request and the
/// list of device tools, Claude decides what to say and/or which tool(s) to call.
struct ClaudeClient {
    var apiKey: String
    var model: String = "claude-sonnet-5"

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func sendTurn(systemPrompt: String, messages: [ClaudeMessage], tools: [[String: Any]]) async throws -> ClaudeTurn {
        guard !apiKey.isEmpty else { throw ClaudeError.missingAPIKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": systemPrompt,
            "tools": tools,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "error desconocido"
            throw ClaudeError.requestFailed(message)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let stopReason = json["stop_reason"] as? String else {
            throw ClaudeError.malformedResponse
        }

        var text = ""
        var toolUses: [(id: String, name: String, input: [String: Any])] = []
        for block in content {
            guard let type = block["type"] as? String else { continue }
            if type == "text", let blockText = block["text"] as? String {
                text += blockText
            } else if type == "tool_use",
                      let id = block["id"] as? String,
                      let name = block["name"] as? String,
                      let input = block["input"] as? [String: Any] {
                toolUses.append((id: id, name: name, input: input))
            }
        }

        return ClaudeTurn(assistantText: text, toolUses: toolUses, rawAssistantContent: content, stopReason: stopReason)
    }
}
