import Foundation
import AVFoundation

/// Keeps the app running while it's in the background waiting on an answer.
///
/// iOS suspends a backgrounded app within about 30 seconds, and a suspended
/// app can't do anything at all — including firing the local notification
/// that tells you your answer is ready. `beginBackgroundTask` only buys that
/// same ~30s, so on its own it can't cover a request that takes minutes.
///
/// The one exception iOS makes is an app that is actively *playing audio*
/// with the `audio` background mode declared (already declared in
/// project.yml for spoken replies). So while a request is in flight in the
/// background, this plays silence on a loop: the app stays alive, the
/// WebSocket stays connected, and the moment the answer arrives it can
/// notify you for real instead of the answer waiting until you next open
/// the app.
///
/// Deliberately only ever runs while backgrounded with a request pending —
/// started from ConversationEngine.handleAppBackgrounded, stopped as soon as
/// the turn resolves or the app comes back to the foreground. That matters
/// for two reasons: it isn't holding the audio hardware (or draining
/// battery) at any other time, and it can never overlap with the mic or with
/// spoken replies, both of which only ever run in the foreground.
///
/// `.mixWithOthers` so it doesn't pause or duck whatever else you're
/// listening to — the whole point is that you've walked away to do
/// something else.
@MainActor
final class BackgroundKeepAlive {
    private var player: AVAudioPlayer?

    var isRunning: Bool { player != nil }

    func start() {
        guard player == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let silence = try AVAudioPlayer(data: Self.silentLoop)
            silence.numberOfLoops = -1
            silence.volume = 0
            silence.play()
            player = silence
        } catch {
            // Nothing to recover here: without the keep-alive the app just
            // gets suspended as usual and the answer is delivered on next
            // launch instead (see ConversationEngine.deliverPendingResultIfAny).
            player = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
    }

    /// Generated rather than shipped as an asset so there's no binary blob
    /// in the repo for something this trivial. One second of 8 kHz mono
    /// silence, looped forever.
    private static let silentLoop: Data = makeSilentWAV(seconds: 1)

    private static func makeSilentWAV(seconds: Int) -> Data {
        let sampleRate: UInt32 = 8000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = UInt32(seconds) * byteRate

        var data = Data()
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF")
        append(UInt32(36) + dataSize)
        append("WAVE")
        append("fmt ")
        append(UInt32(16))      // fmt chunk size
        append(UInt16(1))       // PCM
        append(channels)
        append(sampleRate)
        append(byteRate)
        append(blockAlign)
        append(bitsPerSample)
        append("data")
        append(dataSize)
        data.append(Data(count: Int(dataSize))) // zeroed samples == silence
        return data
    }
}
