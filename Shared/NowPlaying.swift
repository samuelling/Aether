import MediaPlayer
import UIKit

/// Lock screen, Control Center, CarPlay and steering-wheel integration: publishes what's
/// playing and routes play/pause back to the app. Not actor-isolated; call from the main
/// thread (remote-command handlers are delivered on the main thread too).
final class NowPlaying {
    private var lastKey: [String] = []
    private let artwork: MPMediaItemArtwork?

    init(artworkName: String) {
        if let img = UIImage(named: artworkName) {
            artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        } else {
            artwork = nil
        }
    }

    func handleCommands(play: @escaping () -> Void, pause: @escaping () -> Void,
                        isPlaying: @escaping () -> Bool) {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.isEnabled = true
        c.pauseCommand.isEnabled = true
        c.togglePlayPauseCommand.isEnabled = true
        c.playCommand.addTarget { _ in play(); return .success }
        c.pauseCommand.addTarget { _ in pause(); return .success }
        c.togglePlayPauseCommand.addTarget { _ in
            if isPlaying() { pause() } else { play() }
            return .success
        }
        // A live instrument: no tracks to skip, nothing to scrub.
        for cmd in [c.nextTrackCommand, c.previousTrackCommand, c.skipForwardCommand,
                    c.skipBackwardCommand, c.seekForwardCommand, c.seekBackwardCommand] {
            cmd.isEnabled = false
        }
        c.changePlaybackPositionCommand.isEnabled = false
    }

    /// Cheap to call often; only touches the system when something changed.
    func update(title: String, artist: String, album: String, playing: Bool) {
        let key = [title, artist, album, playing ? "1" : "0"]
        guard key != lastKey else { return }
        lastKey = key
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: album,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
