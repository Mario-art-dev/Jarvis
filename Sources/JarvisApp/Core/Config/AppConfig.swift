import Foundation
import Combine

/// Observable view over the credentials in SecureStore, so SwiftUI screens
/// can react to the user filling in the Settings screen.
final class AppConfig: ObservableObject {
    @Published var elevenLabsAPIKey: String
    @Published var elevenLabsVoiceID: String
    /// ws:// or wss:// URL of your Jarvis server (see server/), e.g. ws://192.168.1.20:8787
    @Published var serverURL: String
    /// Must match JARVIS_SERVER_TOKEN in the server's .env
    @Published var serverToken: String

    init() {
        elevenLabsAPIKey = SecureStore.get(.elevenLabsAPIKey) ?? ""
        elevenLabsVoiceID = SecureStore.get(.elevenLabsVoiceID) ?? ""
        serverURL = SecureStore.get(.serverURL) ?? ""
        serverToken = SecureStore.get(.serverToken) ?? ""
    }

    var isConfigured: Bool {
        !elevenLabsAPIKey.isEmpty && !elevenLabsVoiceID.isEmpty && !serverURL.isEmpty && !serverToken.isEmpty
    }

    func save() {
        SecureStore.set(elevenLabsAPIKey, for: .elevenLabsAPIKey)
        SecureStore.set(elevenLabsVoiceID, for: .elevenLabsVoiceID)
        SecureStore.set(serverURL, for: .serverURL)
        SecureStore.set(serverToken, for: .serverToken)
    }
}
