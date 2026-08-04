import Foundation
import UIKit
import MediaPlayer
import AVFoundation

/// Playback controls (pause/resume/skip) and system volume for whatever is
/// currently playing in Music — separate from PlayMusicTool, which picks
/// what plays in the first place.
struct MusicControlTool: JarvisTool {
    let name = "music_control"
    let description = "Controla la reproducción actual de la app Música: pausar, reanudar, siguiente/anterior canción, y subir/bajar el volumen del dispositivo."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["pause", "resume", "next", "previous", "volume_up", "volume_down"]]
        ],
        "required": ["action"]
    ]

    private let volumeStep: Float = 0.1

    func execute(input: [String: Any]) async throws -> String {
        guard let action = input["action"] as? String else {
            throw ToolError.invalidInput("action")
        }

        return await MainActor.run {
            let player = MPMusicPlayerController.systemMusicPlayer
            switch action {
            case "pause":
                player.pause()
                return "Pausado."
            case "resume":
                player.play()
                return "Reproduciendo."
            case "next":
                player.skipToNextItem()
                return "Siguiente canción."
            case "previous":
                player.skipToPreviousItem()
                return "Canción anterior."
            case "volume_up":
                let newVolume = min(1, AVAudioSession.sharedInstance().outputVolume + volumeStep)
                setSystemVolume(newVolume)
                return "Subiendo el volumen."
            case "volume_down":
                let newVolume = max(0, AVAudioSession.sharedInstance().outputVolume - volumeStep)
                setSystemVolume(newVolume)
                return "Bajando el volumen."
            default:
                return "Acción de música desconocida."
            }
        }
    }

    /// iOS has no public API to set the device volume directly — this is
    /// the standard (if hacky) workaround: drive the hidden slider inside
    /// an MPVolumeView, which is the one control surface Apple does let
    /// apps manipulate programmatically.
    @MainActor
    private func setSystemVolume(_ volume: Float) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first else { return }

        let volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        window.addSubview(volumeView)
        if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
            slider.value = volume
        }
        volumeView.removeFromSuperview()
    }
}
