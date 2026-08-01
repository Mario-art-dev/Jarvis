import Foundation
import EventKit

struct CalendarTool: JarvisTool {
    let name = "calendar"
    let description = "Crea o lista eventos del calendario. action=create requiere title, start_iso8601 y opcionalmente end_iso8601. action=list_today no requiere nada más."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["create", "list_today"]],
            "title": ["type": "string"],
            "start_iso8601": ["type": "string", "description": "Fecha/hora ISO8601 de inicio"],
            "end_iso8601": ["type": "string", "description": "Fecha/hora ISO8601 de fin, opcional"]
        ],
        "required": ["action"]
    ]

    private let store = EKEventStore()
    private let isoFormatter = ISO8601DateFormatter()

    func execute(input: [String: Any]) async throws -> String {
        guard try await requestAccess() else {
            throw ToolError.permissionDenied("acceso al Calendario")
        }

        let action = (input["action"] as? String) ?? "list_today"

        if action == "create" {
            guard let title = input["title"] as? String,
                  let startString = input["start_iso8601"] as? String,
                  let start = isoFormatter.date(from: startString) else {
                throw ToolError.invalidInput("title/start_iso8601")
            }
            let end = (input["end_iso8601"] as? String).flatMap(isoFormatter.date(from:)) ?? start.addingTimeInterval(3600)

            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = start
            event.endDate = end
            event.calendar = store.defaultCalendarForNewEvents
            try store.save(event, span: .thisEvent)
            return "He creado el evento \"\(title)\"."
        } else {
            let start = Calendar.current.startOfDay(for: Date())
            let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let events = store.events(matching: predicate)
            if events.isEmpty {
                return "No tienes eventos hoy."
            }
            let summary = events.map { $0.title ?? "(sin título)" }.joined(separator: ", ")
            return "Hoy tienes \(events.count) eventos: \(summary)."
        }
    }

    private func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestFullAccessToEvents { granted, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
