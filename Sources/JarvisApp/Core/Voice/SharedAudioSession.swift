import AVFoundation

/// SpeechRecognizer and AudioPlayer both need the mic and speaker running
/// at the same time — the mic listens for "calla" while Jarvis talks — and
/// on iOS that means sharing one AVAudioSession, a single device-wide
/// resource. Each one independently calling setCategory/setActive on it
/// (even to the exact same category) while the OTHER side already has it
/// actively running was what caused Jarvis to freeze or go silent
/// mid-response before: reconfiguring an already-active session can make
/// iOS renegotiate the hardware audio route, which silently interrupts
/// whichever side was already using it — with no error and no callback
/// telling the other side that happened.
///
/// Funneling both through this one function, which skips the
/// (re)configuration entirely once the session is already in the right
/// state, removes that race instead of trying to carefully order around it.
enum SharedAudioSession {
    static func activateForSimultaneousPlayAndRecord() throws {
        let session = AVAudioSession.sharedInstance()
        // .default, not .voiceChat: .voiceChat is tuned for phone-call-style
        // audio, held to your ear, and applies noticeably quieter output
        // gain even with .defaultToSpeaker set — that's what made Jarvis
        // barely audible on speaker unless you held the phone right up to
        // your ear. .default applies none of that call-specific processing
        // while still allowing simultaneous record+playback under
        // .playAndRecord, which is all this actually needs.
        guard session.category != .playAndRecord || session.mode != .default else { return }
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }
}
