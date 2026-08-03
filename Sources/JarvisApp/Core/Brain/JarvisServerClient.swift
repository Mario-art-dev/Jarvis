import Foundation

enum ServerError: Error, LocalizedError {
    case missingConfig
    case invalidURL
    case connectionClosed(String)

    var errorDescription: String? {
        switch self {
        case .missingConfig: return "Falta la URL o el token del servidor Jarvis. Configúralos en Ajustes."
        case .invalidURL: return "La URL del servidor no es válida."
        case .connectionClosed(let reason): return "Conexión con el servidor perdida: \(reason)"
        }
    }
}

/// Talks to server/ (a small Node process running the Claude Agent SDK,
/// authenticated with your Claude subscription instead of a pay-per-token
/// API key). The wire protocol is deliberately tiny:
///
///   phone -> server: {"type": "user_message", "text": "..."}
///   server -> phone: {"type": "tool_call", "id", "name", "input"}   (may repeat)
///   phone -> server: {"type": "tool_result", "id", "result"}
///   server -> phone: {"type": "final_answer", "text": "..."}
///   server -> phone: {"type": "error", "message": "..."}
///
/// Tool calls are executed locally via ToolRegistry (Photos/EventKit/
/// Contacts/UIApplication all require running on-device), then the result
/// is sent back so the server-side Claude session can continue.
@MainActor
final class JarvisServerClient: NSObject {
    private var task: URLSessionWebSocketTask?
    private let toolRegistry: ToolRegistry

    init(toolRegistry: ToolRegistry) {
        self.toolRegistry = toolRegistry
    }

    /// Sends one user utterance, drives the tool-call loop, and returns the
    /// final spoken answer. Opens a fresh WebSocket per turn — simplest thing
    /// that works reliably on mobile networks that sleep/reconnect often.
    /// `images`, when non-empty, rides along in the same message so Claude
    /// sees the text and the photo(s) together as one turn.
    func ask(_ text: String, images: [ImageAttachment] = [], config: AppConfig) async throws -> String {
        guard !config.serverURL.isEmpty, !config.serverToken.isEmpty else {
            throw ServerError.missingConfig
        }
        guard let url = URL(string: config.serverURL) else {
            throw ServerError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.serverToken)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: request)
        task = ws
        ws.resume()
        defer {
            ws.cancel(with: .normalClosure, reason: nil)
            task = nil
        }

        let imagePayload = images.map { ["media_type": $0.mediaType, "data": $0.data.base64EncodedString()] }
        try await send(["type": "user_message", "text": text, "images": imagePayload], on: ws)

        while true {
            let message = try await ws.receive()
            guard case .string(let jsonString) = message,
                  let data = jsonString.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                continue
            }

            switch type {
            case "final_answer":
                return (json["text"] as? String) ?? "Hecho."

            case "error":
                throw ServerError.connectionClosed((json["message"] as? String) ?? "error desconocido")

            case "tool_call":
                guard let id = json["id"] as? String, let name = json["name"] as? String else { continue }
                let input = (json["input"] as? [String: Any]) ?? [:]
                let result = await executeTool(name: name, input: input)
                try await send(["type": "tool_result", "id": id, "result": result], on: ws)

            default:
                continue
            }
        }
    }

    private func executeTool(name: String, input: [String: Any]) async -> String {
        guard let tool = toolRegistry.tool(named: name) else {
            return "Herramienta desconocida: \(name)"
        }
        do {
            return try await tool.execute(input: input)
        } catch {
            return "Error ejecutando \(name): \(error.localizedDescription)"
        }
    }

    private func send(_ object: [String: Any], on ws: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        try await ws.send(.string(text))
    }
}
