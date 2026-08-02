import SwiftUI

struct ConversationView: View {
    @StateObject private var config = AppConfig()
    @StateObject private var speech = SpeechRecognizer()
    @StateObject private var engine: ConversationEngine
    @State private var showSettings = false

    init() {
        let sharedConfig = AppConfig()
        _config = StateObject(wrappedValue: sharedConfig)
        _engine = StateObject(wrappedValue: ConversationEngine(config: sharedConfig))
    }

    var body: some View {
        ZStack {
            HUDView(state: engine.state)

            VStack {
                HStack {
                    Spacer()
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(.white.opacity(0.8))
                            .padding()
                    }
                }
                Spacer()

                transcriptView

                micButton
                    .padding(.bottom, 40)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(config: config)
        }
        .onAppear {
            if !config.isConfigured {
                showSettings = true
            }
        }
        .onOpenURL { url in
            // jarvisapp://listen — triggered by the Siri Shortcut / Back Tap
            // so saying "Oye Siri, despierta Jarvis" (or a double Back Tap)
            // opens the app and starts listening in one step.
            guard url.host == "listen" else { return }
            if config.isConfigured && !speech.isListening && engine.state == .idle {
                startListening()
            }
        }
        .alert("Error", isPresented: .constant(engine.lastError != nil)) {
            Button("OK") { engine.lastError = nil }
        } message: {
            Text(engine.lastError ?? "")
        }
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(engine.transcript) { entry in
                        Text("\(entry.speaker): \(entry.text)")
                            .foregroundColor(entry.speaker == "Tú" ? .white.opacity(0.7) : Color(red: 0.35, green: 0.9, blue: 1.0))
                            .font(.system(.body, design: .rounded))
                            .id(entry.id)
                    }
                }
                .padding()
            }
            .frame(maxHeight: 220)
            .onChange(of: engine.transcript.count) { _ in
                if let last = engine.transcript.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var micButton: some View {
        Button {
            toggleListening()
        } label: {
            Image(systemName: speech.isListening ? "mic.fill" : "mic")
                .font(.system(size: 30))
                .foregroundColor(.black)
                .frame(width: 76, height: 76)
                .background(speech.isListening ? Color.red : Color(red: 0.35, green: 0.9, blue: 1.0))
                .clipShape(Circle())
                .shadow(color: .cyan.opacity(0.6), radius: 12)
        }
        .disabled(!config.isConfigured || engine.state == .thinking || engine.state == .speaking)
    }

    private func toggleListening() {
        if speech.isListening {
            speech.stopListening()
            let text = speech.transcript
            Task {
                await engine.handleUserUtterance(text)
            }
        } else {
            startListening()
        }
    }

    private func startListening() {
        speech.requestAuthorization { granted in
            guard granted else {
                engine.lastError = "Necesito permiso de micrófono y reconocimiento de voz."
                return
            }
            engine.state = .listening
            speech.startListening()
        }
    }
}

#Preview {
    ConversationView()
}
