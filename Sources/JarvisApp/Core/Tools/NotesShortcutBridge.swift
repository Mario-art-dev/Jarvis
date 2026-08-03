import Foundation
import UIKit

/// Apple gives Calendar/Reminders/Contacts real frameworks for third-party
/// apps (EventKit, Contacts), but not Notes — there's no public API for it
/// at all. The only thing that actually reaches Notes from outside is the
/// Shortcuts app, which Apple grants special access to. So this bridges to
/// two user-built Shortcuts ("Jarvis Crear Nota" / "Jarvis Leer Nota") via
/// the x-callback-url convention: open shortcuts://…, the Shortcut runs,
/// and its result comes back as a URL open into jarvisapp://notes-callback
/// (wired up in ConversationView's onOpenURL). See README for the exact
/// Shortcut setup this depends on.
@MainActor
final class NotesShortcutBridge {
    static let shared = NotesShortcutBridge()
    private init() {}

    private var pending: [String: CheckedContinuation<String, Error>] = [:]

    struct CallbackError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func run(shortcutName: String, input: String, timeout: TimeInterval = 20) async throws -> String {
        let id = UUID().uuidString
        guard let url = buildURL(shortcutName: shortcutName, input: input, id: id) else {
            throw CallbackError(message: "No se pudo construir la llamada al Atajo")
        }

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            UIApplication.shared.open(url)

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let stale = self.pending.removeValue(forKey: id) else { return }
                stale.resume(throwing: CallbackError(
                    message: "El Atajo \"\(shortcutName)\" no respondió a tiempo — ¿existe con ese nombre exacto y tiene desactivado \"Preguntar antes de ejecutar\"?"
                ))
            }
        }
    }

    /// Call from onOpenURL when host == "notes-callback".
    func handleCallback(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let continuation = pending.removeValue(forKey: id) else { return }

        let isError = components.queryItems?.first(where: { $0.name == "error" })?.value == "1"
        if isError {
            continuation.resume(throwing: CallbackError(message: "El Atajo devolvió un error o se canceló."))
        } else {
            let result = components.queryItems?.first(where: { $0.name == "result" })?.value ?? ""
            continuation.resume(returning: result)
        }
    }

    private func buildURL(shortcutName: String, input: String, id: String) -> URL? {
        var components = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")
        components?.queryItems = [
            URLQueryItem(name: "name", value: shortcutName),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: input),
            URLQueryItem(name: "x-success", value: "jarvisapp://notes-callback?id=\(id)"),
            URLQueryItem(name: "x-error", value: "jarvisapp://notes-callback?id=\(id)&error=1")
        ]
        return components?.url
    }
}
