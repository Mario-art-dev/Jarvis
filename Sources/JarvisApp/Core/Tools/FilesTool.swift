import Foundation

/// Creates, reads and lists plain-text files in Jarvis's own sandboxed
/// Documents folder. iOS doesn't give third-party apps write access to
/// arbitrary locations in the Files app — this is the one folder it gets
/// for free, made visible under "En mi iPhone > Jarvis" in Files via
/// UIFileSharingEnabled/LSSupportsOpeningDocumentsInPlace in project.yml.
struct FilesTool: JarvisTool {
    let name = "files_content"
    let description = "Crea, lee o lista archivos de texto en la carpeta de Jarvis dentro de la app Archivos (\"En mi iPhone > Jarvis\"). Solo admite archivos de texto plano, no puede crear ni leer otros tipos de documento (PDF, Word, etc.) ni acceder a carpetas fuera de la suya."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["create", "read", "list"]],
            "filename": ["type": "string", "description": "Para create/read: nombre del archivo, ej. 'lista de la compra.txt'. Si falta la extensión, se añade .txt."],
            "content": ["type": "string", "description": "Solo para create: el texto del archivo."]
        ],
        "required": ["action"]
    ]

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func execute(input: [String: Any]) async throws -> String {
        guard let action = input["action"] as? String else {
            throw ToolError.invalidInput("action")
        }

        switch action {
        case "create":
            guard var filename = input["filename"] as? String, !filename.isEmpty else {
                throw ToolError.invalidInput("filename")
            }
            if !filename.contains(".") { filename += ".txt" }
            let content = (input["content"] as? String) ?? ""
            let url = documentsURL.appendingPathComponent(sanitized(filename))
            try content.write(to: url, atomically: true, encoding: .utf8)
            return "He creado el archivo \"\(filename)\" en la carpeta de Jarvis en Archivos."

        case "read":
            guard let filename = input["filename"] as? String, !filename.isEmpty else {
                throw ToolError.invalidInput("filename")
            }
            guard let match = try findFile(named: filename) else {
                throw ToolError.notSupported("no encontré ningún archivo llamado \"\(filename)\"")
            }
            return try String(contentsOf: match, encoding: .utf8)

        case "list":
            let items = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
                .map { $0.lastPathComponent }
                .sorted()
            if items.isEmpty {
                return "No tienes ningún archivo guardado en la carpeta de Jarvis."
            }
            return "Tienes \(items.count) archivos: \(items.joined(separator: ", "))."

        default:
            throw ToolError.invalidInput("action")
        }
    }

    /// Case-insensitive, extension-optional lookup so "léeme la lista de la
    /// compra" matches "lista de la compra.txt" without the user having to
    /// say the extension.
    private func findFile(named filename: String) throws -> URL? {
        let items = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
        let target = filename.lowercased()
        return items.first {
            let name = $0.lastPathComponent.lowercased()
            return name == target || name == target + ".txt" || $0.deletingPathExtension().lastPathComponent.lowercased() == target
        }
    }

    /// Strips path separators so a filename can't escape the Documents
    /// folder (e.g. "../../something").
    private func sanitized(_ filename: String) -> String {
        filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
    }
}
