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

    // MARK: Next-song prefetch (issue #39)

    /// The one song in the future we keep downloaded ("only 1", per the
    /// issue): its remote URL and the local file it was saved to.
    private var prefetched: (remote: URL, local: URL)?
    /// Remote URL of the download currently in flight (nil if none).
    private var prefetchingURL: URL?
    private var prefetchTask: URLSessionDownloadTask?
    /// Session for the prefetch download. Ephemeral: nothing should be
    /// cached on disk beyond the single song file itself.
    private lazy var prefetchSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// Directory for the prefetched song file (Caches — iOS may purge it,
    /// which is fine: a missing file just falls back to streaming).
    private var prefetchDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory,
                                             in: .userDomainMask)[0]
        return caches.appendingPathComponent("NextSongPrefetch",
                                             isDirectory: true)
    }

    /// Invoked on the main thread when the current item finishes playing
    /// naturally (end of stream). The owning model (AppModel) sets this to
    /// fetch and start the next song (issue #16). Nil if no one is watching.
    var onSongFinished: (() -> Void)?

    init() {
        try? AVAudioSession.sharedInstance()
            .setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        // Prefetched files are only useful within a session; drop any
        // leftovers from a previous launch.
        try? FileManager.default.removeItem(at: prefetchDir)
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
        // Use the prefetched download when we have one for this URL
        // (issue #39): no network round trip, the song starts instantly.
        // Must run before stop(), which tears the prefetch down with the
        // rest of the player state.
        let source = consumePrefetch(for: url) ?? url
        stop()
        try? AVAudioSession.sharedInstance()
            .setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let item = AVPlayerItem(url: source)
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
        // Whatever was queued in the future is no longer wanted (new song
        // starting, station switch, logout) — drop the download and file.
        cancelPrefetch()
        // Release the audio session so other apps can play (the
        // system re-activates it on the next play()).
        try? AVAudioSession.sharedInstance().setActive(false,
            options: .notifyOthersOnDeactivation)
    }

    // MARK: Prefetch

    /// Download the next song's audio in the background so that switching
    /// to it is instant even on a bad network (issue #39). Only one song
    /// is kept ahead: a new prefetch replaces the previous one. Failures
    /// are silent — play(url:) falls back to streaming the remote URL.
    func prefetch(url: URL) {
        // Already have this song (downloaded or downloading) — nothing to do.
        guard prefetched?.remote != url, prefetchingURL != url else { return }
        cancelPrefetch()
        let dir = prefetchDir
        try? FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(UUID().uuidString)
        prefetchingURL = url
        let task = prefetchSession.downloadTask(with: url) {
            [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                guard let self, self.prefetchingURL == url else { return }
                self.prefetchingURL = nil
                self.prefetchTask = nil
                guard error == nil, let tempURL else { return }
                if let http = response as? HTTPURLResponse,
                   http.statusCode != 200 {
                    try? FileManager.default.removeItem(at: tempURL)
                    return
                }
                do {
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                } catch {
                    try? FileManager.default.removeItem(at: tempURL)
                    return
                }
                self.prefetched = (remote: url, local: dest)
            }
        }
        prefetchTask = task
        task.resume()
    }

    /// Drop the current prefetch (if any): cancel an in-flight download
    /// and delete the downloaded file.
    func cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchingURL = nil
        if let p = prefetched {
            try? FileManager.default.removeItem(at: p.local)
        }
        prefetched = nil
    }

    /// If `url` matches the prefetched song, hand back its local file URL
    /// (clearing the entry — the file is now the playing item). Otherwise
    /// nil: play from the network as before.
    private func consumePrefetch(for url: URL) -> URL? {
        guard let p = prefetched, p.remote == url,
              FileManager.default.fileExists(atPath: p.local.path)
        else { return nil }
        prefetched = nil
        return p.local
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
