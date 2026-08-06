import Foundation
import Speech
import AVFoundation

/// Listens for "Jarvis escucha" while Jarvis is idle and the app is
/// backgrounded (screen locked, app not force-quit) — the on-device
/// equivalent of "Hey Jarvis", built with the same Speech framework already
/// used everywhere else in the app rather than a third-party wake-word SDK,
/// so it needs no account, no API key and no extra dependency.
///
/// In the foreground this deliberately never gets a chance to run: Jarvis
/// already listens continuously whenever the app is open and idle (see
/// ConversationView.beginListeningIfIdle), so a wake word would be pure
/// overhead there. Its entire reason to exist is the background case, where
/// nothing else is listening for you at all.
///
/// Own SFSpeechRecognizer and own AVAudioEngine, exactly like
/// InterruptListener and for the same reason: two earlier features that
/// reused the main SpeechRecognizer each left a mic session in a bad state
/// that poisoned the *next* normal listen, which was far worse than the
/// original feature not working. Total isolation contains that risk —
/// worst case here is silently not detecting the phrase, never breaking
/// anything else.
///
/// Unlike InterruptListener, this one *does* own configuring the audio
/// session — it only ever runs when nothing else is (Jarvis idle), so
/// there's no session already set up to inherit. It uses the exact same
/// category/mode/options as AudioPlayer/SpeechRecognizer/SystemVoice so
/// handing off to any of them afterwards needs no reconfiguration (see the
/// click/pop fix elsewhere in this file's siblings) — a mismatch there was
/// once audible as a click on every single turn.
@MainActor
final class WakeWordListener: NSObject {
    private static let triggerPhrase = "jarvis escucha"

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var onTrigger: (() -> Void)?

    /// True when every attempt to arm was refused, so the caller can say so
    /// instead of leaving the user talking to a phone that isn't listening.
    private(set) var failedToArm = false

    private var pendingRetry: DispatchWorkItem?
    private var healthCheck: Timer?
    private var attempt = 0
    private var storedTrigger: (() -> Void)?

    /// How long to wait before each attempt. The first is delayed on purpose:
    /// arming happens immediately after the main recogniser was torn down,
    /// and SFSpeechRecognizer reports itself unavailable for a moment right
    /// after a task ends (SpeechRecognizer.startListening documents the same
    /// thing and retries for it) — while the audio hardware is still being
    /// handed over. All of these fit inside the ~30s iOS allows before
    /// suspending an app that isn't playing or recording anything, which is
    /// the real deadline: if recording never starts, the app is suspended
    /// and the wake word is dead until you open it again.
    /// The first is immediate on purpose: arming is triggered from
    /// scenePhase `.inactive`, which fires while the app is still allowed to
    /// start recording — a window worth catching, since starting a recording
    /// once fully backgrounded is far more likely to be refused.
    private static let attemptDelays: [TimeInterval] = [0, 0.6, 1.5, 3, 6, 12]

    /// Starts listening for the phrase, retrying if the mic or recogniser
    /// isn't ready yet. Every individual failure is silent (this runs
    /// unattended, and the app must keep working regardless), but giving up
    /// entirely sets `failedToArm` so it doesn't fail invisibly.
    func start(onTrigger: @escaping () -> Void) {
        guard task == nil else { return }
        storedTrigger = onTrigger
        attempt = 0
        failedToArm = false
        scheduleNextAttempt()
    }

    private func scheduleNextAttempt() {
        pendingRetry?.cancel()
        guard attempt < Self.attemptDelays.count else {
            // Out of retries: the mic is genuinely unavailable to us right
            // now (another app holding it, recording refused in the
            // background, permissions revoked).
            failedToArm = true
            storedTrigger = nil
            return
        }
        let delay = Self.attemptDelays[attempt]
        attempt += 1

        let work = DispatchWorkItem { [weak self] in
            guard let self, let trigger = self.storedTrigger else { return }
            if !self.attemptStart(onTrigger: trigger) {
                self.scheduleNextAttempt()
            }
        }
        pendingRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// One arming attempt. Returns false if anything wasn't ready, so the
    /// caller can try again rather than the whole feature quietly ending
    /// here — which is exactly what used to happen.
    private func attemptStart(onTrigger: @escaping () -> Void) -> Bool {
        guard task == nil else { return true }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVAudioSession.sharedInstance().recordPermission == .granted,
              let recognizer, recognizer.isAvailable else { return false }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            // Very common on the first attempt: the main recogniser has just
            // deactivated this same session and iOS hasn't finished the
            // handover. Retrying is exactly right here.
            return false
        }

        self.onTrigger = onTrigger

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            newRequest.requiresOnDeviceRecognition = true
        }
        request = newRequest

        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // A zero sample rate means the input hardware isn't actually
        // available right now (ej. mid-transition between apps owning the
        // mic) — installing a tap with that format throws an uncatchable
        // exception, so bail out instead.
        guard format.sampleRate > 0 else {
            teardown()
            return false
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak newRequest] buffer, _ in
            newRequest?.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            teardown()
            return false
        }

        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            guard let self else { return }
            if error != nil {
                // Recognition dies on its own fairly often when it runs this
                // long (silence timeouts, the system reclaiming it). Tearing
                // down and re-arming keeps the wake word alive for the whole
                // time you're away, instead of only until the first hiccup.
                self.teardown()
                if self.storedTrigger != nil {
                    self.attempt = 0
                    self.scheduleNextAttempt()
                }
                return
            }
            guard let heard = result?.bestTranscription.formattedString,
                  Self.containsTrigger(heard) else { return }
            let callback = self.onTrigger
            // The only feedback possible with the screen locked — confirms
            // "heard you, go ahead" without needing to look at the phone.
            // stop() deactivates the audio session, which would cut the
            // chime off mid-play if it ran right away, so it — and handing
            // off to whatever listens for the actual command next — waits
            // until the chime has actually finished.
            let chimeDuration = self.playConfirmationChime()
            DispatchQueue.main.asyncAfter(deadline: .now() + chimeDuration) { [weak self] in
                self?.stop()
                callback?()
            }
        }

        failedToArm = false
        startHealthCheck()
        return true
    }

    private var chimePlayer: AVAudioPlayer?

    /// A short two-tone beep, generated rather than shipped as an audio
    /// asset for the same reason BackgroundKeepAlive's silence is — no
    /// binary blob in the repo for something this simple. Kept in a
    /// property (not a local variable) so ARC doesn't tear it down mid-play.
    /// Returns how long it plays for, so the caller can wait that long
    /// before tearing down the session — 0 if it couldn't play at all.
    @discardableResult
    private func playConfirmationChime() -> TimeInterval {
        do {
            let player = try AVAudioPlayer(data: Self.chimeWAV)
            player.volume = 0.6
            player.play()
            chimePlayer = player
            return player.duration
        } catch {
            // Missing the chime is not worth losing the trigger over.
            return 0
        }
    }

    /// Stops for good: no more retries, nothing left armed. Used when
    /// something else needs the mic (a real turn starting, the app coming
    /// back to the foreground, muting).
    func stop() {
        pendingRetry?.cancel()
        pendingRetry = nil
        storedTrigger = nil
        attempt = 0
        teardown()
        // Deactivating here (unlike InterruptListener, which never touches
        // the session) is correct specifically because this is the only
        // thing using the session while armed — whoever runs next
        // (SpeechRecognizer, AudioPlayer, SystemVoice) configures it fresh
        // for themselves regardless, so there's no shared state to protect
        // by leaving it active.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Releases the mic and recogniser but keeps `storedTrigger`, so a
    /// failed or dropped attempt can be retried without the caller having to
    /// re-arm it.
    private func teardown() {
        healthCheck?.invalidate()
        healthCheck = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        onTrigger = nil
    }

    /// Recognition can stop delivering results without ever reporting an
    /// error — the engine gets stopped by an audio-session interruption (a
    /// phone call, another app taking the mic), and nothing tells us. Left
    /// alone, the wake word would appear armed while being deaf. This
    /// notices within half a minute and re-arms.
    private func startHealthCheck() {
        healthCheck?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.storedTrigger != nil else { return }
                guard self.audioEngine?.isRunning != true else { return }
                self.teardown()
                self.attempt = 0
                self.scheduleNextAttempt()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthCheck = timer
    }

    /// Accent-, case- and punctuation-insensitive, same approach as
    /// InterruptListener's "jarvis calla" matching.
    private static func containsTrigger(_ text: String) -> Bool {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let scrubbed = String(folded.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        let collapsed = scrubbed.split(separator: " ").joined(separator: " ")
        return collapsed.contains(triggerPhrase)
    }

    /// Two short ascending tones (880Hz then 1320Hz, ~90ms each) — a quick
    /// "mm-hm, go ahead" rather than a single flat beep. Faded in/out a few
    /// milliseconds on each tone so there's no click at the edges.
    private static let chimeWAV: Data = makeChimeWAV()

    private static func makeChimeWAV() -> Data {
        let sampleRate: Double = 22050
        let toneDuration: Double = 0.09
        let gapDuration: Double = 0.03
        let fadeDuration: Double = 0.012
        let frequencies: [Double] = [880, 1320]

        var samples: [Int16] = []
        for frequency in frequencies {
            let toneSamples = Int(sampleRate * toneDuration)
            let fadeSamples = Int(sampleRate * fadeDuration)
            for i in 0..<toneSamples {
                let t = Double(i) / sampleRate
                var amplitude = 0.5
                if i < fadeSamples {
                    amplitude *= Double(i) / Double(fadeSamples)
                } else if i > toneSamples - fadeSamples {
                    amplitude *= Double(toneSamples - i) / Double(fadeSamples)
                }
                let value = amplitude * sin(2 * Double.pi * frequency * t)
                samples.append(Int16(value * Double(Int16.max)))
            }
            if frequency != frequencies.last {
                samples.append(contentsOf: repeatElement(0, count: Int(sampleRate * gapDuration)))
            }
        }

        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = UInt32(sampleRate) * UInt32(blockAlign)
        let dataSize = UInt32(samples.count * 2)

        var data = Data()
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF")
        append(UInt32(36) + dataSize)
        append("WAVE")
        append("fmt ")
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(channels)
        append(UInt32(sampleRate))
        append(byteRate)
        append(blockAlign)
        append(bitsPerSample)
        append("data")
        append(dataSize)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
