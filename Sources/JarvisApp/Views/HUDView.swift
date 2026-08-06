import SwiftUI

enum JarvisState {
    case idle
    case listening
    case thinking
    case speaking
}

/// Recreates the circular HUD from the reference image: concentric cyan
/// rings, tick marks and a pulsing core, animated based on assistant state.
/// Also draws an audio-reactive radial waveform, spike beams and shockwave
/// rings around the core, plus the live partial transcript — makes it "feel"
/// like an arc reactor driven by Jarvis's own voice/mic, not a static logo
/// with a mood color.
struct HUDView: View {
    let state: JarvisState
    /// Roughly 0...1, current mic input level (while listening) or speaker
    /// output level (while speaking) — see SpeechRecognizer.audioLevel /
    /// AudioPlayer.audioLevel. Drives every audio-reactive element below:
    /// the radial waveform, the spike beams, the shockwave rings and the
    /// core's extra "kick" on top of its own breathing animation.
    var audioLevel: Float = 0
    /// Partial speech-to-text result, shown under the ring while listening
    /// so you can see Jarvis is actually picking up what you're saying.
    var liveTranscript: String = ""

    @State private var rotation: Double = 0
    @State private var pulse: CGFloat = 1.0
    @State private var shockwave: CGFloat = 0

    private var accentColor: Color {
        switch state {
        case .idle: return Color(red: 0.25, green: 0.85, blue: 0.95)
        case .listening: return Color(red: 0.3, green: 1.0, blue: 0.8)
        case .thinking: return Color(red: 0.6, green: 0.75, blue: 1.0)
        case .speaking: return Color(red: 0.35, green: 0.9, blue: 1.0)
        }
    }

    /// Clamped, easy-to-reuse read of `audioLevel` — every reactive element
    /// below is some function of this single number.
    private var level: CGFloat { CGFloat(min(max(audioLevel, 0), 1)) }

    private let barCount = 40
    private let spikeCount = 16
    private let horizontalBarMultipliers: [CGFloat] = [0.5, 0.8, 1.05, 1.2, 1.0, 0.75, 0.5]

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Color(red: 0.02, green: 0.07, blue: 0.12), .black],
                center: .center, startRadius: 10, endRadius: 400
            )
            .ignoresSafeArea()

            ZStack {
                // Shockwave rings: two overlapping pulses at different phase
                // so they never look like a single "breathing" circle —
                // closer to a reactor discharging than a logo pulsing.
                shockwaveRing(baseRadius: 165, phase: 0)
                shockwaveRing(baseRadius: 165, phase: 0.5)

                spikeBeams(radius: 175, count: spikeCount)
                    .rotationEffect(.degrees(rotation * 0.4))

                tickRing(radius: 150, count: 60, length: 6, lineWidth: 1.5)
                    .rotationEffect(.degrees(rotation + Double(level) * 25))

                radialWaveform(radius: 132, count: barCount)
                    .rotationEffect(.degrees(-rotation * 0.5))

                dashedRing(radius: 118, dash: [10, 6], lineWidth: 2)
                    .rotationEffect(.degrees(-rotation * 0.6 - Double(level) * 40))

                Circle()
                    .stroke(accentColor.opacity(0.8), lineWidth: 2)
                    .frame(width: 170, height: 170)

                blockRing(radius: 85, count: 24)
                    .rotationEffect(.degrees(rotation * 1.3 + Double(level) * 60))

                // Core glow: state gives it a slow breathing baseline, audio
                // level adds a fast, much bigger "kick" on top so it visibly
                // flares with every word instead of only mood-shifting.
                Circle()
                    .fill(accentColor.opacity(0.12 + Double(level) * 0.25))
                    .frame(width: 130, height: 130)
                    .scaleEffect(pulse + level * 0.6)
                    .blur(radius: 8 + level * 10)

                Circle()
                    .stroke(accentColor, lineWidth: 2.5 + level * 3)
                    .frame(width: 118, height: 118)
                    .scaleEffect(1 + level * 0.18)
                    .shadow(color: accentColor, radius: 10 + level * 18)

                Text("J.A.R.V.I.S")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(accentColor)
                    .shadow(color: accentColor, radius: 6 + level * 10)
            }
            .frame(width: 320, height: 320)
            .animation(.easeOut(duration: 0.06), value: audioLevel)

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
            // Faster than before (18s → 11s): a slowly-spinning ring reads as
            // decorative; this reads as a machine actually doing something.
            withAnimation(.linear(duration: 11).repeatForever(autoreverses: false)) {
                rotation = 360
            }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = state == .idle ? 1.0 : 1.35
            }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                shockwave = 1
            }
        }
        .onChange(of: state) { newState in
            withAnimation(.easeInOut(duration: 0.5)) {
                pulse = newState == .idle ? 1.0 : 1.35
            }
        }
    }

    // MARK: - Audio-reactive elements

    /// An expanding, fading ring — the "shockwave" that makes the core feel
    /// like it's discharging energy rather than just glowing. `phase` offsets
    /// its cycle so two of these overlap and never look like one flat pulse.
    private func shockwaveRing(baseRadius: CGFloat, phase: CGFloat) -> some View {
        let t = (shockwave + phase).truncatingRemainder(dividingBy: 1)
        // Louder audio makes each discharge reach further and start bolder,
        // not just happen on a fixed schedule — silence still ticks over
        // gently so the HUD is never fully static.
        let scale = 1 + t * (0.35 + level * 0.5)
        let opacity = (1 - t) * (0.5 + Double(level) * 0.5)
        return Circle()
            .stroke(accentColor, lineWidth: 2)
            .frame(width: baseRadius * 2, height: baseRadius * 2)
            .scaleEffect(scale)
            .opacity(opacity)
    }

    /// Thin beams radiating out from the ring, like light escaping an arc
    /// reactor — length and brightness both track `level`, so they're barely
    /// visible at rest and spike outward on loud syllables.
    private func spikeBeams(radius: CGFloat, count: Int) -> some View {
        ZStack {
            ForEach(0..<count, id: \.self) { i in
                let jitter = 0.5 + 0.5 * sin(Double(i) * 2.4)
                let length = 10 + level * 55 * CGFloat(jitter)
                Capsule()
                    .fill(accentColor.opacity(0.15 + Double(level) * 0.65 * jitter))
                    .frame(width: 2, height: length)
                    .offset(y: -radius)
                    .rotationEffect(.degrees(Double(i) / Double(count) * 360))
            }
        }
    }

    /// The full-circle counterpart to the little `waveform` strip below the
    /// ring: `count` bars arranged all the way around, each with its own
    /// sine-based multiplier so a loud moment looks like an uneven spectrum
    /// bursting outward, not a uniform ring inflating.
    private func radialWaveform(radius: CGFloat, count: Int) -> some View {
        ZStack {
            ForEach(0..<count, id: \.self) { i in
                let multiplier = 0.4 + 0.6 * abs(sin(Double(i) * 2.399963)) // golden-angle-ish spread
                let barLength = 4 + level * 40 * CGFloat(multiplier)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accentColor.opacity(0.35 + Double(level) * 0.55))
                    .frame(width: 3, height: barLength)
                    .offset(y: -radius)
                    .rotationEffect(.degrees(Double(i) / Double(count) * 360))
            }
        }
    }

    /// The small horizontal strip under the ring — kept from the original
    /// design, but with more bars and a much bigger swing so it reads as
    /// "reacting hard" instead of a gentle wobble.
    private var waveform: some View {
        HStack(spacing: 4) {
            ForEach(0..<14, id: \.self) { i in
                let multiplier = horizontalBarMultipliers[i % horizontalBarMultipliers.count]
                RoundedRectangle(cornerRadius: 2)
                    .fill(accentColor)
                    .frame(width: 4, height: barHeight(multiplier: multiplier))
                    .animation(.easeOut(duration: 0.06), value: audioLevel)
            }
        }
        .frame(height: 80)
    }

    private func barHeight(multiplier: CGFloat) -> CGFloat {
        let minHeight: CGFloat = 5
        return minHeight + level * 74 * multiplier
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

#Preview("Alto volumen") {
    HUDView(state: .speaking, audioLevel: 0.95, liveTranscript: "")
}
