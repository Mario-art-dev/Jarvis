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
    /// When on, Jarvis speaks only with the iPhone's own voice: it never asks
    /// the Mac to synthesise and never calls ElevenLabs. Not a secret, so it
    /// lives in UserDefaults rather than the Keychain.
    @Published var preferPhoneVoice: Bool {
        didSet { UserDefaults.standard.set(preferPhoneVoice, forKey: Self.preferPhoneVoiceKey) }
    }

    private static let preferPhoneVoiceKey = "com.mariomontesinos.jarvis.preferPhoneVoice"

    init() {
        elevenLabsAPIKey = SecureStore.get(.elevenLabsAPIKey) ?? ""
        elevenLabsVoiceID = SecureStore.get(.elevenLabsVoiceID) ?? ""
        serverURL = SecureStore.get(.serverURL) ?? ""
        serverToken = SecureStore.get(.serverToken) ?? ""
        preferPhoneVoice = UserDefaults.standard.bool(forKey: Self.preferPhoneVoiceKey)
    }

    /// The server connection is always required (that's where Claude runs);
    /// ElevenLabs only matters when its voice will actually be used.
    var isConfigured: Bool {
        guard !serverURL.isEmpty, !serverToken.isEmpty else { return false }
        return preferPhoneVoice || (!elevenLabsAPIKey.isEmpty && !elevenLabsVoiceID.isEmpty)
    }

    func save() {
        SecureStore.set(elevenLabsAPIKey, for: .elevenLabsAPIKey)
        SecureStore.set(elevenLabsVoiceID, for: .elevenLabsVoiceID)
        SecureStore.set(serverURL, for: .serverURL)
        SecureStore.set(serverToken, for: .serverToken)
    }
}
