import Foundation

enum ServerError: Error, LocalizedError {
    case missingConfig
    case invalidURL
    case connectionClosed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .missingConfig: return "Falta la URL o el token del servidor Jarvis. Configúralos en Ajustes."
        case .invalidURL: return "La URL del servidor no es válida."
        case .connectionClosed(let reason): return "Conexión con el servidor perdida: \(reason)"
        case .timedOut:
            return "Esto está llevando un rato. Sigo dándole vueltas en el servidor — vuelve a entrar en un momento y te cuento en cuanto termine."
        }
    }
}

/// Lets the watchdog Task below signal *why* the socket closed, so a
/// deliberate timeout can be reported as such instead of as whatever
/// generic URLError cancelling a socket happens to surface as. A reference
/// type because the flag is set from inside a closure; both it and the
/// reader run on the main actor (JarvisServerClient is @MainActor and Task
/// inherits that isolation), so there's no concurrent access to guard.
private final class TimeoutFlag {
    var fired = false
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

        // Force-close the socket if nothing arrives within this window —
        // mostly to recover from a connection that died silently (ej. the
        // phone got backgrounded/suspended and the network dropped without
        // either side ever getting a close frame), which otherwise left
        // Jarvis stuck on "pensando" forever with nothing to wake it up.
        //
        // Deliberately generous (5 min): a genuinely long request ("escríbeme
        // un libro") can legitimately take minutes, and giving up early on
        // one of those would be worse than the freeze this guards against.
        // Nothing is lost when it does fire either — the Claude turn keeps
        // running server-side regardless, and backgroundJobs.ts catches the
        // answer for delivery next time the app checks in (see
        // ConversationEngine.deliverPendingResultIfAny).
        let expired = TimeoutFlag()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            expired.fired = true
            ws.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }

        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await ws.receive()
            } catch {
                // Cancelling the socket above surfaces here as a generic
                // URLError, so without this the user would see a cryptic
                // system message instead of ServerError.timedOut's friendly
                // "still working on it" wording.
                if expired.fired { throw ServerError.timedOut }
                throw error
            }

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

    /// Asks the server whether a previous turn finished after this phone
    /// had already disconnected (app closed mid-task, connection dropped)
    /// — see server/src/backgroundJobs.ts. Called once right after the
    /// opening greeting so a long-running request you walked away from
    /// gets delivered as soon as you reopen the app, instead of being lost.
    /// Returns nil on any failure — this is a nice-to-have, not something
    /// that should surface as an error to the user.
    func checkPendingResult(config: AppConfig) async -> String? {
        guard !config.serverURL.isEmpty, !config.serverToken.isEmpty,
              let url = URL(string: config.serverURL) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.serverToken)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: request)
        ws.resume()
        defer { ws.cancel(with: .normalClosure, reason: nil) }

        // Short watchdog — this is a single quick round trip normally, not
        // worth risking greet() hanging forever on a dead connection.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            ws.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }

        do {
            try await send(["type": "check_pending"], on: ws)
            let message = try await ws.receive()
            guard case .string(let jsonString) = message,
                  let data = jsonString.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "pending_result" else {
                return nil
            }
            return json["text"] as? String
        } catch {
            return nil
        }
    }

    /// Asks the server to synthesise this text with Piper, if it's set up
    /// there (see server/src/piper.ts). Returns nil whenever it isn't, or
    /// anything fails — the caller then falls back to ElevenLabs and, past
    /// that, the iPhone's own voice, so an unconfigured or broken Piper is
    /// never the difference between Jarvis speaking and not.
    func synthesize(_ text: String, config: AppConfig) async -> Data? {
        guard !config.serverURL.isEmpty, !config.serverToken.isEmpty,
              let url = URL(string: config.serverURL) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.serverToken)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: request)
        ws.resume()
        defer { ws.cancel(with: .normalClosure, reason: nil) }

        // Local synthesis of a normal reply takes well under this; the point
        // is only to avoid stalling speech behind a wedged connection.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            ws.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }

        do {
            try await send(["type": "synthesize", "text": text], on: ws)
            let message = try await ws.receive()
            guard case .string(let jsonString) = message,
                  let data = jsonString.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "audio",
                  let base64 = json["data"] as? String else {
                return nil
            }
            return Data(base64Encoded: base64)
        } catch {
            return nil
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
