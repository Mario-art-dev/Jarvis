import Foundation

/// Creates alarms and timers by routing through two user-built Shortcuts
/// (reusing NotesShortcutBridge's generic x-callback-url mechanism) — Apple
/// gives no direct framework for the Clock app either, same situation as
/// Notes. Reading existing alarms, remaining timer time, or controlling the
/// stopwatch isn't possible at all: Apple doesn't expose that state to any
/// third-party app, not even Shortcuts, so this tool deliberately doesn't
/// pretend to support it.
struct ClockTool: JarvisTool {
    let name = "clock_action"
    let description = "Crea una alarma nueva o inicia un temporizador de cuenta atrás en el iPhone. Requiere que el usuario tenga configurados los Atajos \"Jarvis Crear Alarma\" y \"Jarvis Iniciar Temporizador\". No puede leer alarmas existentes, ni decir cuánto queda de un temporizador, ni controlar el cronómetro — Apple no lo permite a ninguna app."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["create_alarm", "start_timer"]],
            "time_hhmm": ["type": "string", "description": "Solo para create_alarm: hora en formato 24h HH:mm, ej. '07:30'."],
            "minutes": ["type": "integer", "description": "Solo para start_timer: minutos de cuenta atrás."]
        ],
        "required": ["action"]
    ]

    func execute(input: [String: Any]) async throws -> String {
        guard let action = input["action"] as? String else {
            throw ToolError.invalidInput("action")
        }

        switch action {
        case "create_alarm":
            guard let time = input["time_hhmm"] as? String, !time.isEmpty else {
                throw ToolError.invalidInput("time_hhmm")
            }
            _ = try await NotesShortcutBridge.shared.run(shortcutName: "Jarvis Crear Alarma", input: time)
            return "He creado la alarma a las \(time)."

        case "start_timer":
            guard let minutes = input["minutes"] as? Int, minutes > 0 else {
                throw ToolError.invalidInput("minutes")
            }
            _ = try await NotesShortcutBridge.shared.run(shortcutName: "Jarvis Iniciar Temporizador", input: String(minutes))
            return "He puesto un temporizador de \(minutes) minutos."

        default:
            throw ToolError.invalidInput("action")
        }
    }
}
