import Foundation
import EventKit

struct RemindersTool: JarvisTool {
    let name = "reminders"
    let description = "Crea o lista recordatorios pendientes. action=create requiere title y opcionalmente due_iso8601. action=list_pending no requiere nada más."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["create", "list_pending"]],
            "title": ["type": "string"],
            "due_iso8601": ["type": "string"]
        ],
        "required": ["action"]
    ]

    private let store = EKEventStore()
    private let isoFormatter = ISO8601DateFormatter()

    func execute(input: [String: Any]) async throws -> String {
        guard try await requestAccess() else {
            throw ToolError.permissionDenied("acceso a Recordatorios")
        }

        let action = (input["action"] as? String) ?? "list_pending"

        if action == "create" {
            guard let title = input["title"] as? String else {
                throw ToolError.invalidInput("title")
            }
            let reminder = EKReminder(eventStore: store)
            reminder.title = title
            reminder.calendar = store.defaultCalendarForNewReminders()
            if let dueString = input["due_iso8601"] as? String, let due = isoFormatter.date(from: dueString) {
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            }
            try store.save(reminder, commit: true)
            return "He creado el recordatorio \"\(title)\"."
        } else {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            let reminders = await fetchReminders(matching: predicate)
            if reminders.isEmpty {
                return "No tienes recordatorios pendientes."
            }
            let summary = reminders.prefix(10).map { $0.title ?? "(sin título)" }.joined(separator: ", ")
            return "Tienes \(reminders.count) recordatorios pendientes: \(summary)."
        }
    }

    private func fetchReminders(matching predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    private func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestFullAccessToReminders { granted, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
