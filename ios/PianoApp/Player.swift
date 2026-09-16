//
// Player.swift — audio playback of Pandora stream URLs via AVPlayer.
// (The original pianobar shells out to ffplay; on iOS we stream the
// song's audioUrl directly — both AAC+ and MP3, which AVPlayer handles.)
//
// Failures (ATS, expired CDN tokens, bad codec) are surfaced via `lastError`
// instead of dying silently.
//
// Copyright (c) 2025 Spencer Graffunder
// MIT licensed.
//

import AVFoundation
import Combine
import Foundation

/// Minimal AVPlayer wrapper with a small observable state.
final class Player: ObservableObject {
    @Published private(set) var isPlaying = false
    /// Set when the current item fails to load/play; cleared on a new play.
    @Published private(set) var lastError: String?
    /// Set when the current item reached its end. Cleared on a new play.
    /// Used to tell "resume a paused song" from "restart an ended one".
    @Published private(set) var itemFinished = false
    @Published var volume: Float = 0.8

    private var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    /// Invoked on the main thread when the current item finishes playing
    /// naturally (end of stream). The owning model (AppModel) sets this to
    /// fetch and start the next song (issue #16). Nil if no one is watching.
    var onSongFinished: (() -> Void)?

    init() {
        try? AVAudioSession.sharedInstance()
            .setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    /// Watch an item for load failures and end-of-stream.
    private func observe(_ item: AVPlayerItem) {
        // KVO on status catches load failures (e.g. NSURLErrorDomain -1022
        // "App Transport Security requires a secure connection", 403 from an
        // expired CDN token, unsupported codec).
        statusObservation = item.observe(\.status, options: [.new]) {
            [weak self] it, _ in
            guard let self else { return }
            if it.status == .failed {
                let err = it.error
                self.lastError = "Playback failed: " +
                    (err?.localizedDescription ?? "unknown error")
                self.isPlaying = false
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item,
            queue: .main) { [weak self] _ in
            self?.isPlaying = false
            // The song finished: mark it so we don't "resume" it (issue #27),
            // then let the owner advance to the next one (issue #16 —
            // previously playback just stopped here).
            self?.itemFinished = true
            self?.onSongFinished?()
        }
    }

    func play(url: URL) {
        stop()
        try? AVAudioSession.sharedInstance()
            .setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.volume = volume
        player = newPlayer
        observe(item)
        lastError = nil
        itemFinished = false
        newPlayer.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func stop() {
        player?.pause()
        player = nil
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        isPlaying = false
        // Release the audio session so other apps can play (the
        // system re-activates it on the next play()).
        try? AVAudioSession.sharedInstance().setActive(false,
            options: .notifyOthersOnDeactivation)
    }

    // MARK: Now Playing support

    /// Elapsed playback time of the current item (0 if none/unknown).
    var elapsed: Double {
        let t = player?.currentTime() ?? .zero
        let s = t.seconds
        return s.isFinite ? max(0, s) : 0
    }

    /// Duration of the current item (0 if not yet known).
    var duration: Double {
        guard let d = player?.currentItem?.duration, d.seconds.isFinite,
              d.seconds > 0 else { return 0 }
        return d.seconds
    }

    /// True only when AVPlayer is *actually* producing audio right now
    /// (not just when we asked it to). Drives the Now Playing transport
    /// icon: publishing `playbackRate` from intent instead of reality is
    /// what made the Control Center icon flicker while the stream buffered.
    var isActivelyPlaying: Bool {
        player?.timeControlStatus == .playing
    }

    /// A song is loaded that can be resumed (not yet finished, and we
    /// haven't torn the player down). Lets the model resume from a
    /// lock-screen/Control-Center Play instead of restarting from 0:00.
    var canResume: Bool {
        guard let p = player, !itemFinished else { return false }
        return p.currentItem != nil
    }

    /// Resume the current item (used by media-session auto-resume).
    func resume() {
        guard let player else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
    }

    /// `PlayerLike` conformance: (re)start the current item.
    func play() {
        resume()
    }

    // MARK: Volume

    func setVolume(_ v: Float) {
        volume = min(max(0, v), 1)
        player?.volume = volume
    }

    func nudgeVolume(_ delta: Float) {
        setVolume(volume + delta)
    }

    func resetVolume() {
        setVolume(0.8)
    }
}
