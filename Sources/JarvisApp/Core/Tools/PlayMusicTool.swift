import Foundation
import MediaPlayer

/// Plays a playlist from the user's Apple Music / local Music library by
/// name, optionally shuffled — via MediaPlayer, not just opening the Music
/// app. Only finds playlists already in the user's library (personal
/// playlists, or Apple Music playlists they've saved); it can't search the
/// whole Apple Music catalog for playlists they've never added.
struct PlayMusicTool: JarvisTool {
    let name = "play_music"
    let description = "Reproduce una playlist de la app Música por nombre, opcionalmente aleatoria (shuffle). Solo encuentra playlists que ya están en la biblioteca del usuario."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "playlist_name": ["type": "string", "description": "Nombre (o parte del nombre) de la playlist a buscar"],
            "shuffle": ["type": "boolean", "description": "Si es true, activa reproducción aleatoria"]
        ],
        "required": ["playlist_name"]
    ]

    func execute(input: [String: Any]) async throws -> String {
        guard let playlistName = input["playlist_name"] as? String, !playlistName.isEmpty else {
            throw ToolError.invalidInput("playlist_name")
        }
        let shuffle = (input["shuffle"] as? Bool) ?? false

        guard await requestAuthorization() else {
            throw ToolError.permissionDenied("acceso a la biblioteca de Música")
        }

        let query = MPMediaQuery.playlists()
        guard let collections = query.collections else {
            throw ToolError.notSupported("no se pudo leer la biblioteca de Música")
        }

        let match = collections.first { collection -> Bool in
            guard let playlist = collection as? MPMediaPlaylist else { return false }
            return playlist.name?.localizedCaseInsensitiveContains(playlistName) ?? false
        }

        guard let playlist = match as? MPMediaPlaylist else {
            throw ToolError.notSupported("no encontré ninguna playlist llamada \"\(playlistName)\"")
        }

        await MainActor.run {
            let player = MPMusicPlayerController.systemMusicPlayer
            player.setQueue(with: playlist)
            player.shuffleMode = shuffle ? .songs : .off
            player.play()
        }

        let displayName = playlist.name ?? playlistName
        return shuffle
            ? "Reproduciendo \"\(displayName)\" en aleatorio."
            : "Reproduciendo \"\(displayName)\"."
    }

    private func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
