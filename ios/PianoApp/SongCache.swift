//
// SongCache.swift — persistent, size-capped song audio cache.
//
// Plays songs from local storage instead of redownloading: when a cached
// song comes up again (Pandora re-plays tracks fairly often), it starts
// instantly and works even with no network at all.
//
// Rules (per Spec, 2026-11-01):
//  - Configurable size cap; policy: every song, or only loved songs.
//  - When the cache is full, the OLDEST songs are deleted to fit new ones,
//    but ONLY once they are more than a month old — fresher songs are never
//    evicted, so the cache may temporarily ride over its cap.
//  - "Age" counts from last access (a song you keep playing stays fresh).
//  - Tapping Ban or Tired on a cached song removes it from the cache.
//
// The class is pure Foundation + injectable directory/clock so the whole
// policy (hits, persistence, aging, eviction) runs in unit tests.
//
// Copyright (c) 2025 Spencer Graffunder
// MIT licensed.
//

import Foundation
#if canImport(FoundationNetworking)
// Linux (unit-test harness): URLSession lives in FoundationNetworking.
import FoundationNetworking
#endif

/// Which songs get written to the cache.
enum CachePolicy: String, Equatable {
    /// Cache every song as it plays.
    case anySongs = "any"
    /// Cache only loved songs (they are the ones likely to come back).
    case lovedOnly = "loved"
}

/// The on-disk audio cache: files + a JSON index + eviction policy.
@MainActor
final class SongCache {
    // UserDefaults keys (registered with defaults so "Off" (=0) written
    // later is distinguishable from "never set").
    static let sizeDefaultsKey = "cache-size-mb"
    static let policyDefaultsKey = "cache-policy"
    static let defaultSizeMB = 500

    /// "More than a month old" per the eviction rule.
    static let monthSeconds: TimeInterval = 30 * 24 * 3600

    struct Entry: Codable {
        let key: String
        let fileName: String
        let bytes: Int64
        let addedAt: Date
        /// Drives eviction order AND the month-old test — a song that keeps
        /// getting played never becomes eviction material.
        var lastAccessed: Date
        let title: String
        let artist: String
    }

    struct Stats: Equatable {
        var count = 0
        var bytes: Int64 = 0
        /// Bytes belonging to entries not accessed for over a month
        /// (the "may be evicted" segment of the usage bar).
        var agedBytes: Int64 = 0
        var capBytes: Int64 = 0
    }

    /// Cache directory override (unit tests point this at a temp dir).
    private let directory: URL
    private let defaults: UserDefaults
    private let session: URLSession
    private var entries: [String: Entry] = [:]
    private var inFlight: Set<String> = []

    /// Injectable clock so tests can age entries deterministically.
    var now: @MainActor () -> Date = { Date() }
    /// Fired after anything that changes usage (store/remove/evict).
    var onChange: (@MainActor () -> Void)?

    var sizeMB: Int {
        get { defaults.integer(forKey: Self.sizeDefaultsKey) }
        set {
            defaults.set(newValue, forKey: Self.sizeDefaultsKey)
            evictIfNeeded()
        }
    }
    var policy: CachePolicy {
        get {
            CachePolicy(rawValue: defaults.string(forKey: Self.policyDefaultsKey) ?? "")
                ?? .anySongs
        }
        set { defaults.set(newValue.rawValue, forKey: Self.policyDefaultsKey) }
    }
    var isEnabled: Bool { sizeMB > 0 }
    var capBytes: Int64 { Int64(sizeMB) * 1_000_000 }

    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        defaults.register(defaults: [
            Self.sizeDefaultsKey: Self.defaultSizeMB,
            Self.policyDefaultsKey: CachePolicy.anySongs.rawValue,
        ])
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("SongCache", isDirectory: true)
        }
        var config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        session = URLSession(configuration: config)
        try? FileManager.default.createDirectory(
            at: self.directory, withIntermediateDirectories: true)
        // Don't back up cached audio — it is re-downloadable. (API per
        // Apple's "Optimizing Your App's Data for iCloud Backup"; works on
        // a directory that already exists, which createDirectory just made
        // sure of. Xcode 26 URL has no setResourceValue(_:forKey:) — this
        // is the URLResourceValues form.)
        #if os(iOS)
        var cacheDir = self.directory
        var backupValues = URLResourceValues()
        backupValues.isExcludedFromBackup = true
        try? cacheDir.setResourceValues(backupValues)
        #endif
        loadIndex()
    }

    // MARK: - Keys

    /// Stable cache key for a song. Pandora's musicId is stable across
    /// playlist fetches (the trackToken is NOT); fall back to a stable
    /// hash of artist+title for anything without an id.
    nonisolated static func key(forMusicId musicId: String?,
                                title: String?, artist: String?) -> String? {
        if let m = musicId, !m.isEmpty { return sanitize(m) }
        let t = title ?? "", a = artist ?? ""
        guard !t.isEmpty || !a.isEmpty else { return nil }
        return "h" + stableHash("\(a)\u{1}\(t)")
    }

    private nonisolated static func sanitize(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        let kept = String(String.UnicodeScalarView(
            s.unicodeScalars.filter { allowed.contains($0) }))
        if !kept.isEmpty { return String(kept.prefix(64)) }
        return "h" + stableHash(s)
    }

    /// Deterministic across launches (unlike hashValue, which is seeded
    /// per-process).
    private nonisolated static func stableHash(_ s: String) -> String {
        var h: UInt64 = 5381
        for b in s.utf8 { h = h &* 33 &+ UInt64(b) }
        return String(h, radix: 36)
    }

    // MARK: - Lookups

    /// The local file for a song key, or nil when not cached. Dangling
    /// index rows (file deleted behind our back) are dropped lazily.
    func cachedFileURL(forKey key: String?) -> URL? {
        guard let key, let entry = entries[key] else { return nil }
        let url = directory.appendingPathComponent(entry.fileName)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        entries.removeValue(forKey: key)
        saveIndex()
        onChange?()
        return nil
    }

    /// Bump an entry's age clock (called when playback actually starts
    /// from the cache).
    func markPlayed(forKey key: String?) {
        guard let key, var entry = entries[key] else { return }
        entry.lastAccessed = now()
        entries[key] = entry
        saveIndex()
    }

    // MARK: - Writes

    /// Start caching a song: hit or duplicate → no-op; otherwise download
    /// the remote audio in the background and insert it. Silent on failure
    /// (the song already streams fine — this is a bonus copy).
    func ensureCached(key: String?, remoteURL: URL?,
                      title: String, artist: String) {
        guard isEnabled, let key, let remoteURL else { return }
        guard entries[key] == nil, !inFlight.contains(key) else { return }
        inFlight.insert(key)
        let ext = Self.audioExtension(remoteURL)
        session.downloadTask(with: remoteURL) { [weak self] tmp, response, error in
            // The temp file is deleted when this closure returns, so the
            // move into the cache dir must happen right here (off-main is
            // fine — it's a file move on the same volume).
            guard let self, error == nil, let tmp,
                  let status = (response as? HTTPURLResponse)?.statusCode,
                  (200..<300).contains(status) else {
                Task { @MainActor [weak self] in
                    self?.inFlight.remove(key)
                }
                return
            }
            let dest = self.cacheDirCopyPath(key: key, ext: ext)
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
            } catch {
                NSLog("SongCache: download move failed for %@: %@", key,
                      error.localizedDescription)
                Task { @MainActor [weak self] in
                    self?.inFlight.remove(key)
                }
                return
            }
            Task { @MainActor [weak self] in
                self?.inFlight.remove(key)
                guard let self, self.isEnabled else {
                    try? FileManager.default.removeItem(at: dest)
                    return
                }
                self.insertFile(at: dest, key: key, title: title,
                                artist: artist, ext: ext)
            }
        }.resume()
    }

    /// Nonisolated: called from the URLSession completion handler (off
    /// main) to move the temp download straight into the cache dir. Safe
    /// because `directory` is an immutable Sendable `let`.
    private nonisolated func cacheDirCopyPath(key: String, ext: String) -> URL {
        directory.appendingPathComponent(key + "." + ext)
    }

    /// Insert an already-downloaded file (a prefetch temp file, or a
    /// finished background download) into the cache. Moves the file, then
    /// runs eviction. Takes exactly the file's real size into account.
    func insertFile(at fileURL: URL, key: String,
                    title: String, artist: String, ext: String) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int64, size > 0 else {
            NSLog("SongCache: cannot stat %@ — not cached", key)
            return
        }
        let dest = cacheDirCopyPath(key: key, ext: ext)
        if fileURL != dest {
            // Replace any older file for this key (extension may have changed).
            if let old = entries[key] {
                try? fm.removeItem(
                    at: directory.appendingPathComponent(old.fileName))
            }
            do {
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: fileURL, to: dest)
            } catch {
                NSLog("SongCache: move failed for %@: %@", key,
                      error.localizedDescription)
                return
            }
        }
        let date = now()
        entries[key] = Entry(key: key, fileName: dest.lastPathComponent,
                             bytes: size, addedAt: date, lastAccessed: date,
                             title: title, artist: artist)
        evictIfNeeded()
        saveIndex()
        onChange?()
    }

    /// Remove a song from the cache (Tired). Silently no-ops when absent.
    func remove(forKey key: String?) {
        guard let key, let entry = entries.removeValue(forKey: key) else { return }
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(entry.fileName))
        saveIndex()
        onChange?()
    }

    // MARK: - Eviction

    /// While over the cap, delete the least-recently-accessed entries to
    /// fit new ones — but ONLY once they are more than a month old.
    /// Entries younger than a month are never evicted, so the cache may
    /// ride over its cap until something ages enough (Spec's rule).
    func evictIfNeeded() {
        guard capBytes > 0 else { return }
        var guardCount = entries.count
        while totalBytes() > capBytes, guardCount > 0 {
            guardCount -= 1
            let oldest = entries.values
                .min { $0.lastAccessed < $1.lastAccessed }
            guard let victim = oldest,
                  now().timeIntervalSince(victim.lastAccessed) > Self.monthSeconds
            else { break }
            entries.removeValue(forKey: victim.key)
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(victim.fileName))
        }
        saveIndex()
        onChange?()
    }

    // MARK: - Stats

    func stats() -> Stats {
        var s = Stats(capBytes: capBytes)
        let cutoff = now().addingTimeInterval(-Self.monthSeconds)
        for e in entries.values {
            s.count += 1
            s.bytes += e.bytes
            if e.lastAccessed < cutoff { s.agedBytes += e.bytes }
        }
        return s
    }

    private func totalBytes() -> Int64 {
        entries.values.reduce(0) { $0 + $1.bytes }
    }

    // MARK: - Index persistence

    private var indexURL: URL {
        directory.appendingPathComponent("index.json")
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        let fm = FileManager.default
        for entry in decoded
        where fm.fileExists(atPath:
            directory.appendingPathComponent(entry.fileName).path) {
            entries[entry.key] = entry
        }
    }

    private func saveIndex() {
        let list = Array(entries.values)
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// File extension for cached audio: the remote URL's own extension
    /// when it looks sane (Pandora serves .m4a/.aac/.mp3), else m4a.
    private nonisolated static func audioExtension(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return (["m4a", "aac", "mp3"].contains(ext)) ? ext : "m4a"
    }
}
