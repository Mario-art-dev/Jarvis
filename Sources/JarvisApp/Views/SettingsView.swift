import SwiftUI

struct SettingsView: View {
    @ObservedObject var config: AppConfig
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("Anthropic (Claude)") {
                    SecureField("API key (sk-ant-...)", text: $config.anthropicAPIKey)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    Text("Créala en console.anthropic.com → Settings → API Keys.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("ElevenLabs (voz)") {
                    SecureField("API key", text: $config.elevenLabsAPIKey)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    TextField("Voice ID (de tu voz clonada)", text: $config.elevenLabsVoiceID)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    Text("Clona tu voz en elevenlabs.io → Voices → Add Voice → Instant Voice Clone, y copia el Voice ID resultante.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section {
                    Text("Estas claves se guardan cifradas en el Llavero de iOS, nunca en el código ni en la nube de Jarvis.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Ajustes")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        config.save()
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView(config: AppConfig())
}
