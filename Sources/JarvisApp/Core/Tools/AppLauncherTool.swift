import Foundation
import UIKit

/// Opens other apps via public URL schemes / universal links. This is the
/// iOS-legal equivalent of "launch app X" — there's no API to list every
/// installed app or to control what happens inside them once opened.
struct AppLauncherTool: JarvisTool {
    let name = "open_app"
    let description = "Abre una app o acción del sistema conocida: maps, mail, messages, phone, facetime, camera, calendar, reminders, settings, whatsapp, spotify, instagram."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "target": [
                "type": "string",
                "enum": ["maps", "mail", "messages", "phone", "facetime", "camera", "calendar", "reminders", "settings", "whatsapp", "spotify", "instagram"]
            ],
            "query_or_recipient": [
                "type": "string",
                "description": "Opcional: dirección para maps, destinatario para messages/mail/phone, etc."
            ]
        ],
        "required": ["target"]
    ]

    func execute(input: [String: Any]) async throws -> String {
        guard let target = input["target"] as? String else {
            throw ToolError.invalidInput("target")
        }
        let extra = (input["query_or_recipient"] as? String) ?? ""

        guard let url = urlFor(target: target, extra: extra) else {
            throw ToolError.notSupported(target)
        }

        let opened = await MainActor.run { () -> Bool in
            guard UIApplication.shared.canOpenURL(url) else { return false }
            UIApplication.shared.open(url)
            return true
        }

        guard opened else {
            throw ToolError.notSupported("\(target) no está instalada o no se puede abrir")
        }
        return "Abriendo \(target)."
    }

    private func urlFor(target: String, extra: String) -> URL? {
        let encoded = extra.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        switch target {
        case "maps":
            return URL(string: "maps://?q=\(encoded)")
        case "mail":
            return URL(string: "mailto:\(extra)")
        case "messages":
            return URL(string: "sms:\(extra)")
        case "phone":
            return URL(string: "tel:\(extra)")
        case "facetime":
            return URL(string: "facetime:\(extra)")
        case "camera":
            return URL(string: "camera://")
        case "calendar":
            return URL(string: "calshow://")
        case "reminders":
            return URL(string: "x-apple-reminder://")
        case "settings":
            return URL(string: UIApplication.openSettingsURLString)
        case "whatsapp":
            return extra.isEmpty ? URL(string: "whatsapp://") : URL(string: "whatsapp://send?phone=\(encoded)")
        case "spotify":
            return URL(string: "spotify://")
        case "instagram":
            return URL(string: "instagram://app")
        default:
            return nil
        }
    }
}
