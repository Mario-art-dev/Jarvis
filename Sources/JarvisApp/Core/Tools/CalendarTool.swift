import Foundation
import EventKit

struct CalendarTool: JarvisTool {
    let name = "calendar"
    let description = "Crea o lista eventos del calendario. action=create requiere title y start_iso8601. Para consultar: list_today (hoy), list_week (próximos 7 días), list_month (próximos 30 días) o list_range con start_iso8601/end_iso8601 para cualquier otro periodo."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["create", "list_today", "list_week", "list_month", "list_range"]],
            "title": ["type": "string"],
            "start_iso8601": ["type": "string", "description": "Fecha/hora ISO8601 de inicio. Para create, cuándo empieza el evento; para list_range, desde cuándo consultar."],
            "end_iso8601": ["type": "string", "description": "Fecha/hora ISO8601 de fin, opcional. Para create, cuándo acaba (por defecto 1h); para list_range, hasta cuándo consultar."]
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
        }

        let (start, end, label) = try range(for: action, input: input)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        // events(matching:) makes no ordering promise, and for anything
        // longer than a day an unordered list is useless to read out.
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        guard !events.isEmpty else {
            return "No tienes eventos \(label)."
        }
        return "\(label.prefix(1).uppercased())\(label.dropFirst()) tienes \(events.count) \(events.count == 1 ? "evento" : "eventos"): \(summarize(events, from: start))."
    }

    /// Resolves an action into the window to query, plus how to refer to it
    /// out loud. Windows run from the start of today rather than "right
    /// now", so an event earlier today still counts as being today.
    private func range(for action: String, input: [String: Any]) throws -> (Date, Date, String) {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())

        switch action {
        case "list_week":
            let end = calendar.date(byAdding: .day, value: 7, to: startOfToday) ?? startOfToday
            return (startOfToday, end, "en los próximos 7 días")
        case "list_month":
            let end = calendar.date(byAdding: .day, value: 30, to: startOfToday) ?? startOfToday
            return (startOfToday, end, "en los próximos 30 días")
        case "list_range":
            guard let startString = input["start_iso8601"] as? String,
                  let start = isoFormatter.date(from: startString) else {
                throw ToolError.invalidInput("start_iso8601")
            }
            // Without an explicit end, read it as "that whole day".
            let end = (input["end_iso8601"] as? String).flatMap(isoFormatter.date(from:))
                ?? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))
                ?? start
            return (start, end, "en ese periodo")
        default: // list_today
            let end = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
            return (startOfToday, end, "hoy")
        }
    }

    /// One line per event with its day and time, since a bare list of titles
    /// tells you nothing across a week or a month. Capped so a busy month
    /// doesn't turn into a wall of text being read aloud.
    private func summarize(_ events: [EKEvent], from rangeStart: Date) -> String {
        let maxListed = 20
        let listed = events.prefix(maxListed).map { event -> String in
            let title = event.title ?? "(sin título)"
            return "\(when(event, relativeTo: rangeStart)) \(title)"
        }
        let remainder = events.count - listed.count
        let tail = remainder > 0 ? ", y \(remainder) más" : ""
        return listed.joined(separator: "; ") + tail
    }

    private func when(_ event: EKEvent, relativeTo rangeStart: Date) -> String {
        let calendar = Calendar.current
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "es_ES")

        // A single-day query already says "hoy", so repeating the date on
        // every line would just be noise — the time alone is enough.
        let singleDayRange = calendar.isDate(rangeStart, inSameDayAs: event.startDate)
            && calendar.isDateInToday(rangeStart)
        if singleDayRange {
            guard !event.isAllDay else { return "todo el día:" }
            dayFormatter.dateFormat = "HH:mm"
            return "\(dayFormatter.string(from: event.startDate)):"
        }

        dayFormatter.dateFormat = event.isAllDay ? "EEEE d 'de' MMMM" : "EEEE d 'de' MMMM 'a las' HH:mm"
        return "\(dayFormatter.string(from: event.startDate)):"
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
