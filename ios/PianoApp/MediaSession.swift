//
// MediaSession.swift — iOS Now Playing + system remote control.
//
//  - MPNowPlayingInfoCenter: title/artist/album/duration/elapsed so the
//    lock screen, Control Center, and the Dynamic Island all show what's
//    playing and which transport state we're in.
//  - MPRemoteCommandCenter: Play / Pause / Play-Pause / Next / Previous
//    from the lock screen, Control Center, wired-headphone inline remote,
//    Bluetooth (AVRCP) controls, and the Apple Watch.
//  - AVAudioSession interruptions: pause when a phone call / Siri takes
//    audio; auto-resume when the interruption ends (if it allows it).
//  - Route changes: pause when the current output device goes away
//    (headphones unplugged, Bluetooth device out of range).
//
// Copyright (c) 2025 Spencer Graffunder
// MIT licensed.
//

import AVFoundation
import Foundation
import MediaPlayer

/// The playback surface the media layer drives. `Player` conforms;
/// tests can substitute a fake.
protocol PlayerLike: AnyObject {
    var isPlaying: Bool { get }
    func play()
    func pause()
}

extension Player: PlayerLike {}

/// The app actions the media layer drives. `AppModel` conforms;
/// tests can substitute a recording fake.
protocol MediaSessionModel: AnyObject {
    /// Whether playback is currently active (drives the toggle command).
    var isPlayingNow: Bool { get }
    /// Title/artist/album of the current song (nils if none).
    var npTitle: String? { get }
    var npArtist: String? { get }
    var npAlbum: String? { get }
    /// Duration of the current song in seconds (0 if unknown).
    var npDuration: Double { get }
    /// Elapsed playback time of the current song in seconds.
    var npElapsed: Double { get }
    /// Whether the player is actually producing audio right now. Drives
    /// the Now Playing transport icon — intent alone would flicker while
    /// the stream is still buffering.
    func npActivelyPlaying() -> Bool
    func modelPlay()
    func modelPause()
    func modelNext()
    func modelPrevious()
    /// Whether playback could be resumed right now (a song is loaded).
    func resumable() -> Bool
}

final class MediaSession {
    /// Model actions — held weakly (the app owns the session).
    private weak var model: MediaSessionModel?

    private let center = MPRemoteCommandCenter.shared()

    private var elapsedTimer: Timer?

    init(model: MediaSessionModel) {
        self.model = model
        wireRemoteCommands()
        wireAudioSession()
    }

    deinit {
        elapsedTimer?.invalidate()
    }

    // MARK: Remote commands

    /// Play/Pause/Next/Previous handlers. `MPRemoteCommandHandlerStatus`
    /// values are dispatched back to the main actor (the model is
    /// main-actor isolated).
    private func wireRemoteCommands() {
        // Enable explicitly — next/previous may default to disabled.
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        // Each handler must return MPRemoteCommandHandlerStatus.
        _ = center.playCommand.addTarget(handler: { [weak self] _ in
            self?.handle(.play); return .success
        })
        _ = center.pauseCommand.addTarget(handler: { [weak self] _ in
            self?.handle(.pause); return .success
        })
        _ = center.togglePlayPauseCommand.addTarget(handler: { [weak self] _ in
            self?.handle(.toggle); return .success
        })
        _ = center.nextTrackCommand.addTarget(handler: { [weak self] _ in
            self?.handle(.next); return .success
        })
        _ = center.previousTrackCommand.addTarget(handler: { [weak self] _ in
            self?.handle(.previous); return .success
        })
    }

    enum Command { case play, pause, toggle, next, previous }

    /// Dispatch a transport command to the model. Called from the
    /// registered remote-command handlers; tests call it directly
    /// (`MPRemoteCommand` has no public `invoke` in the simulator
    /// SDK, so wiring is verified through this seam).
    func handle(_ command: Command) {
        MainActor.assumeIsolated {
            switch command {
            case .play: model?.modelPlay()
            case .pause: model?.modelPause()
            case .toggle:
                if model?.isPlayingNow == true {
                    model?.modelPause()
                } else {
                    model?.modelPlay()
                }
            case .next: model?.modelNext()
            case .previous: model?.modelPrevious()
            }
        }
    }

    // MARK: Now Playing info

    /// Publish the current song + transport state to the system
    /// Now Playing UI (lock screen / Control Center / Dynamic Island).
    ///
    /// `playing` is the user's *intent* — it drives the elapsed-time
    /// timer (keep refreshing the position while we're meant to be
    /// playing). `activelyPlaying` is what AVPlayer is *actually doing*
    /// right now — it drives the transport icon. Separating the two is
    /// what stops the Control Center icon flickering play→pause→play
    /// while a stream is still buffering: we no longer claim "playing"
    /// until audio is really flowing.
    func updateNowPlaying(title: String?, artist: String?, album: String?,
                          duration: Double, elapsed: Double,
                          playing: Bool, activelyPlaying: Bool) {
        var info: [String: Any] = [:]
        if let t = title { info[MPMediaItemPropertyTitle] = t }
        if let a = artist { info[MPMediaItemPropertyArtist] = a }
        if let al = album { info[MPMediaItemPropertyAlbumTitle] = al }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, elapsed)
        info[MPNowPlayingInfoPropertyPlaybackRate] = activelyPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if playing {
            startElapsedTimer()
        } else {
            stopElapsedTimer()
        }
    }

    /// Clear the Now Playing UI (e.g. on logout).
    func clearNowPlaying() {
        stopElapsedTimer()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let m = self.model,
                      m.isPlayingNow else { return }
                self.updateNowPlaying(
                    title: m.npTitle, artist: m.npArtist, album: m.npAlbum,
                    duration: m.npDuration, elapsed: m.npElapsed,
                    playing: true, activelyPlaying: m.npActivelyPlaying())
            }
        }
        RunLoop.main.add(t, forMode: .common)
        elapsedTimer = t
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: Audio session (interruptions + route changes)

    private func wireAudioSession() {
        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance())
        nc.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance())
    }

    @objc private func handleInterruption(_ note: Notification) {
        MainActor.assumeIsolated {
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey]
                as? UInt else { return }
            let type = AVAudioSession.InterruptionType(rawValue: raw)
            switch type {
            case .began:
                // A call / Siri / another app took the audio. Pause.
                model?.modelPause()
            case .ended:
                let opts = AVAudioSession.InterruptionOptions(
                    rawValue: (note.userInfo?[
                        AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0)
                if opts.contains(.shouldResume) {
                    if model?.resumable() == true { model?.modelPlay() }
                }
            case .none:
                break
            @unknown default:
                break
            }
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        MainActor.assumeIsolated {
            guard let raw = note.userInfo?[
                AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            // Only react to the output device going away (headphones
            // unplugged, Bluetooth device out of range): the session
            // then falls back to the speaker. Ignore overrides (another
            // app), category changes, and new devices becoming
            // available.
            // Standard behavior: the output device went away (headphones
            // unplugged, Bluetooth out of range), so pause. (We don't
            // inspect the new port — `AVAudioSessionPort` is a string
            // enum and the fallback is handled by the system.)
            if reason == .oldDeviceUnavailable {
                model?.modelPause()
            }
        }
    }

    // MARK: Tests

    /// Test hook: simulate a route change with the given reason.
    func simulateRouteChange(reason: AVAudioSession.RouteChangeReason) {
        MainActor.assumeIsolated {
            if reason == .oldDeviceUnavailable {
                model?.modelPause()
            }
        }
    }

    /// Test hook: simulate an interruption began/ended.
    func simulateInterruption(
        began: Bool, shouldResume: Bool) {
        MainActor.assumeIsolated {
            if began {
                model?.modelPause()
            } else if shouldResume, model?.resumable() == true {
                model?.modelPlay()
            }
        }
    }
}
