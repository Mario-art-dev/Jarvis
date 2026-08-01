import SwiftUI

struct SettingsView: View {
    @ObservedObject var config: AppConfig
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("Servidor Jarvis (Claude Code)") {
                    TextField("ws://192.168.1.20:8787", text: $config.serverURL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                    SecureField("Server Token", text: $config.serverToken)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    Text("Es la dirección y el token del servidor de carpeta server/ que corre en tu Mac/PC con Claude Code (ver README). Debe estar en la misma red que el móvil, o accesible por Tailscale.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("ElevenLabs (voz)") {
                    SecureField("API key", text: $config.elevenLabsAPIKey)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    TextField("Voice ID", text: $config.elevenLabsVoiceID)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    Text("En elevenlabs.io/app → tu voz elegida (clonada o de la biblioteca) → copia su Voice ID. La API key está en tu perfil → API Keys.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section {
                    Text("Estas claves se guardan cifradas en el Llavero de iOS, nunca en el código ni suben a ningún sitio salvo a tu propio servidor.")
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
