import Foundation

enum ElevenLabsError: Error, LocalizedError {
    case missingCredentials
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Falta la API key o el Voice ID de ElevenLabs. Configúralos en Ajustes."
        case .requestFailed(let message):
            return "ElevenLabs: \(message)"
        }
    }
}

/// Minimal client for ElevenLabs text-to-speech using a cloned voice.
/// The voice itself is created once in the ElevenLabs dashboard/app
/// (Voice Lab -> Instant/Professional Voice Clone) — this client only
/// consumes the resulting voiceID, it never records or uploads audio.
struct ElevenLabsClient {
    var apiKey: String
    var voiceID: String

    /// modelID left as "eleven_multilingual_v2" so cloned voices work well in Spanish.
    var modelID: String = "eleven_multilingual_v2"

    func synthesizeSpeech(text: String) async throws -> Data {
        guard !apiKey.isEmpty, !voiceID.isEmpty else {
            throw ElevenLabsError.missingCredentials
        }

        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)") else {
            throw ElevenLabsError.requestFailed("URL inválida")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": modelID,
            "voice_settings": [
                "stability": 0.45,
                "similarity_boost": 0.85,
                "style": 0.3,
                "use_speaker_boost": true
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "error desconocido"
            throw ElevenLabsError.requestFailed(message)
        }
        return data
    }
}
