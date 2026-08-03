import Foundation
import UIKit

/// Opens other apps via public URL schemes / universal links. This is the
/// iOS-legal equivalent of "launch app X" — there's no API to list every
/// installed app or open one that doesn't have a known scheme, so this list
/// is deliberately explicit rather than a generic "open anything."
///
/// Several schemes below (movistar_plus, hbo_max, brawl_stars,
/// clash_royale, chatgpt, claude, clock, weather) are best-effort guesses
/// at undocumented or unverifiable third-party schemes — there's no way to
/// confirm them without a real device with each app installed. If one
/// doesn't work, canOpenURL just reports it as unavailable (see
/// ToolError.notSupported below); it fails safely rather than crashing.
struct AppLauncherTool: JarvisTool {
    let name = "open_app"
    let description = "Abre una app o acción del sistema conocida por su nombre."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "target": [
                "type": "string",
                "enum": [
                    "maps", "google_maps", "mail", "messages", "phone", "facetime", "camera",
                    "calendar", "reminders", "settings", "whatsapp", "spotify",
                    "instagram", "tiktok", "youtube", "gmail", "chrome", "teams",
                    "app_store", "music", "notes", "voice_memos", "files",
                    "chatgpt", "claude", "netflix", "prime_video", "movistar_plus",
                    "hbo_max", "brawl_stars", "clash_royale", "capcut", "canva",
                    "clock", "weather"
                ]
            ],
            "query_or_recipient": [
                "type": "string",
                "description": "Opcional: dirección para maps/google_maps, destinatario para messages/mail/phone/whatsapp, término de búsqueda para youtube/app_store (para app_store, busca la app en la App Store para que el usuario solo tenga que tocar Instalar — nunca instala nada automáticamente, eso iOS no lo permite a ninguna app)."
            ]
        ],
        "required": ["target"]
    ]

    func execute(input: [String: Any]) async throws -> String {
        guard let target = input["target"] as? String else {
            throw ToolError.invalidInput("target")
        }
        let extra = (input["query_or_recipient"] as? String) ?? ""
        let candidates = urlCandidates(target: target, extra: extra)

        guard !candidates.isEmpty else {
            throw ToolError.notSupported(target)
        }

        let opened = await MainActor.run { () -> Bool in
            for url in candidates where UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return true
            }
            return false
        }

        guard opened else {
            throw ToolError.notSupported("\(target) no está instalada o no se puede abrir")
        }
        return "Abriendo \(target)."
    }

    /// Returns candidate URLs in priority order — the first one iOS reports
    /// it can actually open wins. Used for "settings", where the ideal
    /// (opening the general Settings screen) relies on an undocumented
    /// scheme Apple has restricted for third-party apps on and off over the
    /// years; if it doesn't work on this iOS version, it falls back to the
    /// one Apple guarantees (Jarvis's own page inside Settings).
    private func urlCandidates(target: String, extra: String) -> [URL] {
        let encoded = extra.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        switch target {
        case "maps":
            return [URL(string: "maps://?q=\(encoded)")].compactMap { $0 }
        case "google_maps":
            let url = extra.isEmpty ? URL(string: "comgooglemaps://") : URL(string: "comgooglemaps://?q=\(encoded)")
            return [url].compactMap { $0 }
        case "mail":
            return [URL(string: "mailto:\(extra)")].compactMap { $0 }
        case "messages":
            return [URL(string: "sms:\(extra)")].compactMap { $0 }
        case "phone":
            return [URL(string: "tel:\(extra)")].compactMap { $0 }
        case "facetime":
            return [URL(string: "facetime:\(extra)")].compactMap { $0 }
        case "camera":
            return [URL(string: "camera://")].compactMap { $0 }
        case "calendar":
            return [URL(string: "calshow://")].compactMap { $0 }
        case "reminders":
            return [URL(string: "x-apple-reminder://")].compactMap { $0 }
        case "settings":
            return [
                URL(string: "App-prefs:root=General"),
                URL(string: UIApplication.openSettingsURLString)
            ].compactMap { $0 }
        case "whatsapp":
            let url = extra.isEmpty ? URL(string: "whatsapp://") : URL(string: "whatsapp://send?phone=\(encoded)")
            return [url].compactMap { $0 }
        case "spotify":
            return [URL(string: "spotify://")].compactMap { $0 }
        case "instagram":
            return [URL(string: "instagram://app")].compactMap { $0 }
        case "tiktok":
            return [URL(string: "tiktok://")].compactMap { $0 }
        case "youtube":
            let url = extra.isEmpty ? URL(string: "youtube://") : URL(string: "youtube://results?search_query=\(encoded)")
            return [url].compactMap { $0 }
        case "gmail":
            return [URL(string: "googlegmail://")].compactMap { $0 }
        case "chrome":
            return [URL(string: "googlechrome://")].compactMap { $0 }
        case "teams":
            return [URL(string: "msteams://")].compactMap { $0 }
        case "app_store":
            let url = extra.isEmpty ? URL(string: "itms-apps://") : URL(string: "itms-apps://itunes.apple.com/search?term=\(encoded)")
            return [url].compactMap { $0 }
        case "music":
            return [URL(string: "music://")].compactMap { $0 }
        case "notes":
            return [URL(string: "mobilenotes://")].compactMap { $0 }
        case "voice_memos":
            return [URL(string: "voicememos://")].compactMap { $0 }
        case "files":
            return [URL(string: "shareddocuments://")].compactMap { $0 }
        case "chatgpt":
            return [URL(string: "chatgpt://")].compactMap { $0 }
        case "claude":
            return [URL(string: "claude://")].compactMap { $0 }
        case "netflix":
            return [URL(string: "nflx://")].compactMap { $0 }
        case "prime_video":
            return [URL(string: "primevideo://")].compactMap { $0 }
        case "movistar_plus":
            return [URL(string: "movistarplus://")].compactMap { $0 }
        case "hbo_max":
            return [URL(string: "hbomax://"), URL(string: "max://")].compactMap { $0 }
        case "brawl_stars":
            return [URL(string: "brawlstars://")].compactMap { $0 }
        case "clash_royale":
            return [URL(string: "clashroyale://")].compactMap { $0 }
        case "capcut":
            return [URL(string: "capcut://")].compactMap { $0 }
        case "canva":
            return [URL(string: "canva://")].compactMap { $0 }
        case "clock":
            return [URL(string: "clock-alarm://")].compactMap { $0 }
        case "weather":
            return [URL(string: "weather://")].compactMap { $0 }
        default:
            return []
        }
    }
}
