import Foundation
import UIKit

/// Opens other apps via public URL schemes / universal links. This is the
/// iOS-legal equivalent of "launch app X" — there's no API to list every
/// installed app or open one that doesn't have a known scheme, so this list
/// is deliberately explicit rather than a generic "open anything."
struct AppLauncherTool: JarvisTool {
    let name = "open_app"
    let description = "Abre una app o acción del sistema conocida por su nombre."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "target": [
                "type": "string",
                "enum": [
                    "maps", "mail", "messages", "phone", "facetime", "camera",
                    "calendar", "reminders", "settings", "whatsapp", "spotify",
                    "instagram", "tiktok", "youtube", "gmail", "chrome", "teams",
                    "app_store", "music", "notes", "voice_memos", "files"
                ]
            ],
            "query_or_recipient": [
                "type": "string",
                "description": "Opcional: dirección para maps, destinatario para messages/mail/phone/whatsapp, término de búsqueda para youtube/app_store."
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
        case "tiktok":
            return URL(string: "tiktok://")
        case "youtube":
            return extra.isEmpty ? URL(string: "youtube://") : URL(string: "youtube://results?search_query=\(encoded)")
        case "gmail":
            return URL(string: "googlegmail://")
        case "chrome":
            return URL(string: "googlechrome://")
        case "teams":
            return URL(string: "msteams://")
        case "app_store":
            return extra.isEmpty ? URL(string: "itms-apps://") : URL(string: "itms-apps://itunes.apple.com/search?term=\(encoded)")
        case "music":
            return URL(string: "music://")
        case "notes":
            return URL(string: "mobilenotes://")
        case "voice_memos":
            return URL(string: "voicememos://")
        case "files":
            return URL(string: "shareddocuments://")
        default:
            return nil
        }
    }
}
