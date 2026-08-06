import Foundation

/// Which commit this build was compiled from, and when — shown in Settings
/// so "¿esto ya lo tengo instalado?" has a real answer instead of a guess.
///
/// The values below are placeholders for local/Xcode builds. The GitHub
/// Actions workflow (.github/workflows/build-ipa.yml) overwrites this file
/// with the real commit hash and build time right before `xcodegen generate`
/// runs, so every IPA downloaded from Actions carries its own build stamp.
enum BuildInfo {
    static let commit = "dev"
    static let builtAt = "sin compilar en CI"
}
