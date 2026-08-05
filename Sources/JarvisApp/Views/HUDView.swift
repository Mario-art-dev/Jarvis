import SwiftUI

enum JarvisState {
    case idle
    case listening
    case thinking
    case speaking
}

/// Recreates the circular HUD from the reference image: concentric cyan
/// rings, tick marks and a pulsing core, animated based on assistant state.
/// Also draws a small audio-reactive waveform and, while listening, the
/// live partial transcript — makes it "feel" like Jarvis is actually
/// hearing/speaking in the moment instead of just showing a static mood.
struct HUDView: View {
    let state: JarvisState
    /// Roughly 0...1, current mic input level (while listening) or speaker
    /// output level (while speaking) — see SpeechRecognizer.audioLevel /
    /// AudioPlayer.audioLevel. Drives the waveform bars below the ring.
    var audioLevel: Float = 0
    /// Partial speech-to-text result, shown under the ring while listening
    /// so you can see Jarvis is actually picking up what you're saying.
    var liveTranscript: String = ""

    @State private var rotation: Double = 0
    @State private var pulse: CGFloat = 1.0

    private var accentColor: Color {
        switch state {
        case .idle: return Color(red: 0.25, green: 0.85, blue: 0.95)
        case .listening: return Color(red: 0.3, green: 1.0, blue: 0.8)
        case .thinking: return Color(red: 0.6, green: 0.75, blue: 1.0)
        case .speaking: return Color(red: 0.35, green: 0.9, blue: 1.0)
        }
    }

    private let barMultipliers: [CGFloat] = [0.5, 0.8, 1.05, 1.2, 1.0, 0.75, 0.5]

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Color(red: 0.02, green: 0.07, blue: 0.12), .black],
                center: .center, startRadius: 10, endRadius: 400
            )
            .ignoresSafeArea()

            ZStack {
                tickRing(radius: 150, count: 60, length: 6, lineWidth: 1.5)
                    .rotationEffect(.degrees(rotation))

                dashedRing(radius: 118, dash: [10, 6], lineWidth: 2)
                    .rotationEffect(.degrees(-rotation * 0.6))

                Circle()
                    .stroke(accentColor.opacity(0.8), lineWidth: 2)
                    .frame(width: 170, height: 170)

                blockRing(radius: 85, count: 24)
                    .rotationEffect(.degrees(rotation * 1.3))

                Circle()
                    .fill(accentColor.opacity(0.12))
                    .frame(width: 130, height: 130)
                    .scaleEffect(pulse)
                    .blur(radius: 8)

                Circle()
                    .stroke(accentColor, lineWidth: 2.5)
                    .frame(width: 118, height: 118)
                    .shadow(color: accentColor, radius: 10)

                Text("J.A.R.V.I.S")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(accentColor)
                    .shadow(color: accentColor, radius: 6)
            }
            .frame(width: 320, height: 320)

            VStack {
                Spacer()
                waveform
                    .padding(.bottom, 12)
                if !liveTranscript.isEmpty {
                    Text(liveTranscript)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 32)
                }
                Spacer().frame(height: 90)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) {
                rotation = 360
            }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = state == .idle ? 1.0 : 1.25
            }
        }
        .onChange(of: state) { newState in
            withAnimation(.easeInOut(duration: 0.6)) {
                pulse = newState == .idle ? 1.0 : 1.25
            }
        }
    }

    private var waveform: some View {
        HStack(spacing: 5) {
            ForEach(0..<barMultipliers.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(accentColor)
                    .frame(width: 4, height: barHeight(multiplier: barMultipliers[i]))
                    .animation(.easeOut(duration: 0.08), value: audioLevel)
            }
        }
        .frame(height: 56)
    }

    private func barHeight(multiplier: CGFloat) -> CGFloat {
        let minHeight: CGFloat = 5
        let level = CGFloat(min(max(audioLevel, 0), 1))
        return minHeight + level * 46 * multiplier
    }

    private func tickRing(radius: CGFloat, count: Int, length: CGFloat, lineWidth: CGFloat) -> some View {
        ZStack {
            ForEach(0..<count, id: \.self) { i in
                Rectangle()
                    .fill(accentColor.opacity(i % 5 == 0 ? 0.9 : 0.4))
                    .frame(width: lineWidth, height: i % 5 == 0 ? length * 1.8 : length)
                    .offset(y: -radius)
                    .rotationEffect(.degrees(Double(i) / Double(count) * 360))
            }
        }
    }

    private func dashedRing(radius: CGFloat, dash: [CGFloat], lineWidth: CGFloat) -> some View {
        Circle()
            .stroke(accentColor.opacity(0.7), style: StrokeStyle(lineWidth: lineWidth, dash: dash))
            .frame(width: radius * 2, height: radius * 2)
    }

    private func blockRing(radius: CGFloat, count: Int) -> some View {
        ZStack {
            ForEach(0..<count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(accentColor.opacity(0.6))
                    .frame(width: 8, height: 4)
                    .offset(y: -radius)
                    .rotationEffect(.degrees(Double(i) / Double(count) * 360))
            }
        }
    }
}

#Preview {
    HUDView(state: .listening, audioLevel: 0.4, liveTranscript: "qué tiempo hace mañana")
}
