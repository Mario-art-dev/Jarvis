import Foundation

/// A single capability Jarvis can invoke on the device. Each tool declares
/// its own JSON schema (sent to Claude for tool-use) and knows how to
/// execute itself and return a short text result Jarvis can speak back.
protocol JarvisTool {
    /// Name Claude will use to call this tool. Must match `^[a-zA-Z0-9_-]+$`.
    var name: String { get }
    var description: String { get }
    /// JSON Schema (as used by the Anthropic Messages API "input_schema" field).
    var inputSchema: [String: Any] { get }

    /// Executes the tool with the arguments Claude provided and returns a
    /// short natural-language result to feed back into the conversation.
    func execute(input: [String: Any]) async throws -> String
}

enum ToolError: Error, LocalizedError {
    case permissionDenied(String)
    case invalidInput(String)
    case notSupported(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let what): return "Permiso denegado: \(what)"
        case .invalidInput(let what): return "Entrada inválida: \(what)"
        case .notSupported(let what): return "No soportado: \(what)"
        }
    }
}

/// Central place that owns every tool instance and can look one up by name.
@MainActor
final class ToolRegistry {
    let tools: [JarvisTool]

    init() {
        tools = [
            WebSearchTool(),
            AppLauncherTool(),
            PhotosTool(),
            CalendarTool(),
            RemindersTool(),
            ContactsTool(),
            PlayMusicTool(),
            NotesTool()
        ]
    }

    func tool(named name: String) -> JarvisTool? {
        tools.first { $0.name == name }
    }

    /// Anthropic Messages API "tools" array.
    var claudeToolDefinitions: [[String: Any]] {
        tools.map {
            [
                "name": $0.name,
                "description": $0.description,
                "input_schema": $0.inputSchema
            ]
        }
    }
}
