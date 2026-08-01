import Foundation
import Combine

/// Observable view over the credentials in SecureStore, so SwiftUI screens
/// can react to the user filling in the Settings screen.
final class AppConfig: ObservableObject {
    @Published var anthropicAPIKey: String
    @Published var elevenLabsAPIKey: String
    @Published var elevenLabsVoiceID: String

    init() {
        anthropicAPIKey = SecureStore.get(.anthropicAPIKey) ?? ""
        elevenLabsAPIKey = SecureStore.get(.elevenLabsAPIKey) ?? ""
        elevenLabsVoiceID = SecureStore.get(.elevenLabsVoiceID) ?? ""
    }

    var isConfigured: Bool {
        !anthropicAPIKey.isEmpty && !elevenLabsAPIKey.isEmpty && !elevenLabsVoiceID.isEmpty
    }

    func save() {
        SecureStore.set(anthropicAPIKey, for: .anthropicAPIKey)
        SecureStore.set(elevenLabsAPIKey, for: .elevenLabsAPIKey)
        SecureStore.set(elevenLabsVoiceID, for: .elevenLabsVoiceID)
    }
}
