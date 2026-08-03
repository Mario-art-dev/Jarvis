import Foundation

/// Creates or reads Apple Notes by routing through two user-built Shortcuts
/// (see NotesShortcutBridge and the README) — there's no direct framework
/// for this, so it only works once those Shortcuts exist with the exact
/// names below.
struct NotesTool: JarvisTool {
    let name = "notes_content"
    let description = "Crea una nota nueva con un contenido dado, o lee el contenido de una nota existente por título. Requiere que el usuario tenga configurados los Atajos \"Jarvis Crear Nota\" y \"Jarvis Leer Nota\"."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["create", "read"]],
            "title": ["type": "string", "description": "Para create: título de la nota nueva. Para read: título (o parte del título) de la nota a buscar."],
            "content": ["type": "string", "description": "Solo para create: el texto de la nota."]
        ],
        "required": ["action", "title"]
    ]

    func execute(input: [String: Any]) async throws -> String {
        guard let action = input["action"] as? String,
              let title = input["title"] as? String, !title.isEmpty else {
            throw ToolError.invalidInput("action/title")
        }

        switch action {
        case "create":
            let content = (input["content"] as? String) ?? ""
            let body = content.isEmpty ? title : "\(title)\n\(content)"
            _ = try await NotesShortcutBridge.shared.run(shortcutName: "Jarvis Crear Nota", input: body)
            return "He creado la nota \"\(title)\"."

        case "read":
            let result = try await NotesShortcutBridge.shared.run(shortcutName: "Jarvis Leer Nota", input: title)
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError.notSupported("no encontré ninguna nota que coincida con \"\(title)\"")
            }
            return result

        default:
            throw ToolError.invalidInput("action")
        }
    }
}
