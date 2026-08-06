import Foundation
import UserNotifications

/// Alarms and timers, implemented with local notifications inside Jarvis
/// rather than by driving Apple's Clock app.
///
/// Apple exposes no API for the Clock app, so the previous version routed
/// through two Shortcuts the user had to build by hand ("Jarvis Crear
/// Alarma" / "Jarvis Iniciar Temporizador"). That works when they exist and
/// are named exactly right, and silently times out when they don't — which
/// is a lot of setup to get wrong for something this basic.
///
/// Scheduling notifications ourselves needs no setup at all and, as a bonus,
/// lifts the old "can't read or cancel existing alarms" limitation: these
/// are Jarvis's own notifications, so it can list and cancel them.
///
/// The trade-off, stated plainly in what it tells the user: a notification
/// is not a real Clock alarm. It won't break through silent mode or Do Not
/// Disturb (that needs Apple's critical-alerts entitlement, which requires a
/// paid developer account and Apple's approval), it rings once instead of
/// until dismissed, and it doesn't show up in the Clock app.
struct ClockTool: JarvisTool {
    let name = "clock_action"
    let description = "Crea alarmas y temporizadores, y consulta o cancela los que estén puestos. Son notificaciones de Jarvis: suenan como una notificación normal, no atraviesan el modo silencio ni aparecen en la app Reloj de Apple."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["create_alarm", "start_timer", "list_pending", "cancel_all"]],
            "time_hhmm": ["type": "string", "description": "Solo para create_alarm: hora en formato 24h HH:mm, ej. '07:30'."],
            "label": ["type": "string", "description": "Solo para create_alarm: nombre de la alarma, si el usuario pidió uno."],
            "minutes": ["type": "integer", "description": "Solo para start_timer: minutos de cuenta atrás."]
        ],
        "required": ["action"]
    ]

    private static let alarmPrefix = "jarvis-alarm-"
    private static let timerPrefix = "jarvis-timer-"

    /// Alarms and timers are local notifications, so with notifications off
    /// they can be scheduled and simply never appear — the one failure here
    /// that looks exactly like "alarms don't work" while nothing is actually
    /// broken. Worth spelling out the exact path to fix it, since it's in
    /// iOS Settings rather than anywhere inside Jarvis.
    private static let notificationsDeniedMessage =
        "Jarvis no tiene permiso para enviarte notificaciones, y las alarmas y temporizadores son notificaciones, así que no sonarían. Actívalo en Ajustes del iPhone, Notificaciones, Jarvis, y permite las notificaciones. Luego vuelve a pedírmelo."

    func execute(input: [String: Any]) async throws -> String {
        guard let action = input["action"] as? String else {
            throw ToolError.invalidInput("action")
        }

        switch action {
        case "create_alarm":
            return try await createAlarm(input: input)
        case "start_timer":
            return try await startTimer(input: input)
        case "list_pending":
            return await listPending()
        case "cancel_all":
            return await cancelAll()
        default:
            throw ToolError.invalidInput("action")
        }
    }

    private func createAlarm(input: [String: Any]) async throws -> String {
        guard let time = (input["time_hhmm"] as? String)?.trimmingCharacters(in: .whitespaces),
              let components = parseTime(time) else {
            throw ToolError.invalidInput("time_hhmm (formato HH:mm, ej. 07:30)")
        }
        guard try await ensureNotificationsAllowed() else {
            throw ToolError.permissionDenied(Self.notificationsDeniedMessage)
        }

        let rawLabel = (input["label"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let label = rawLabel.isEmpty ? "Alarma" : rawLabel

        let content = UNMutableNotificationContent()
        content.title = "⏰ \(label)"
        content.body = "Son las \(time)."
        content.sound = .default

        // repeats: false so it fires at the next occurrence of that time and
        // then stops — "ponme una alarma a las 7:30" means tomorrow morning,
        // not every morning forever.
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: Self.alarmPrefix + UUID().uuidString, content: content, trigger: trigger)
        try await UNUserNotificationCenter.current().add(request)

        let when = nextOccurrenceDescription(of: components)
        return "Alarma \"\(label)\" puesta para \(when) a las \(time)."
    }

    private func startTimer(input: [String: Any]) async throws -> String {
        guard let minutes = input["minutes"] as? Int, minutes > 0 else {
            throw ToolError.invalidInput("minutes")
        }
        guard try await ensureNotificationsAllowed() else {
            throw ToolError.permissionDenied(Self.notificationsDeniedMessage)
        }

        let content = UNMutableNotificationContent()
        content.title = "⏱️ Temporizador"
        content.body = minutes == 1 ? "Ha pasado 1 minuto." : "Han pasado \(minutes) minutos."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(minutes) * 60, repeats: false)
        let request = UNNotificationRequest(identifier: Self.timerPrefix + UUID().uuidString, content: content, trigger: trigger)
        try await UNUserNotificationCenter.current().add(request)

        return minutes == 1 ? "Temporizador de 1 minuto en marcha." : "Temporizador de \(minutes) minutos en marcha."
    }

    private func listPending() async -> String {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let alarms = pending.filter { $0.identifier.hasPrefix(Self.alarmPrefix) }
        let timers = pending.filter { $0.identifier.hasPrefix(Self.timerPrefix) }

        guard !alarms.isEmpty || !timers.isEmpty else {
            return "No tienes ninguna alarma ni temporizador puesto."
        }

        var parts: [String] = []
        if !alarms.isEmpty {
            let described = alarms.compactMap { request -> String? in
                guard let trigger = request.trigger as? UNCalendarNotificationTrigger,
                      let hour = trigger.dateComponents.hour,
                      let minute = trigger.dateComponents.minute else { return nil }
                let name = request.content.title.replacingOccurrences(of: "⏰ ", with: "")
                return String(format: "%@ a las %02d:%02d", name, hour, minute)
            }
            parts.append("alarmas: \(described.joined(separator: ", "))")
        }
        if !timers.isEmpty {
            let described = timers.compactMap { request -> String? in
                guard let trigger = request.trigger as? UNTimeIntervalNotificationTrigger,
                      let fireDate = trigger.nextTriggerDate() else { return nil }
                let remaining = max(0, Int(fireDate.timeIntervalSinceNow / 60))
                return remaining <= 1 ? "uno acaba en menos de un minuto" : "uno acaba en \(remaining) minutos"
            }
            parts.append("temporizadores: \(described.joined(separator: ", "))")
        }
        return "Tienes " + parts.joined(separator: "; ") + "."
    }

    private func cancelAll() async -> String {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.alarmPrefix) || $0.hasPrefix(Self.timerPrefix) }

        guard !ids.isEmpty else {
            return "No había ninguna alarma ni temporizador que cancelar."
        }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        return ids.count == 1
            ? "Cancelado."
            : "He cancelado \(ids.count) alarmas y temporizadores."
    }

    /// Accepts "07:30" and also the "7:30" a speech transcript is likely to
    /// produce, rejecting anything out of range.
    private func parseTime(_ text: String) -> DateComponents? {
        let pieces = text.split(separator: ":")
        guard pieces.count == 2,
              let hour = Int(pieces[0]), let minute = Int(pieces[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return DateComponents(hour: hour, minute: minute)
    }

    /// "hoy" or "mañana", so the confirmation is unambiguous about which
    /// occurrence of that time was meant.
    private func nextOccurrenceDescription(of components: DateComponents) -> String {
        let calendar = Calendar.current
        guard let next = calendar.nextDate(after: Date(), matching: components, matchingPolicy: .nextTime) else {
            return "la próxima vez que sea esa hora"
        }
        return calendar.isDateInToday(next) ? "hoy" : "mañana"
    }

    private func ensureNotificationsAllowed() async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            return false
        }
    }
}
