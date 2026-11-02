//
// SongCacheTests.swift — tests for the persistent song cache policy.
//
// Covers: cache hits + index persistence across "relaunches", the age
// split in stats, Tired-removal, dangling-index cleanup — and the two
// eviction rules: fresh (< 1 month) songs are NEVER evicted (cap may be
// exceeded), while month-plus songs evict oldest-first to fit new ones.
//
// The cache runs with an injected temp directory and fake clock, so the
// whole policy is exercised deterministically.
//
// Copyright (c) 2025 Spencer Graffunder
// MIT licensed.
//

import XCTest
@testable import PianoApp

@MainActor
final class SongCacheTests: XCTestCase {

    // MARK: Helpers

    private var cache: SongCache!
    private var dir: URL!
    private var suiteName: String!
    private var fakeDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeCache(sizeMB: Int) -> SongCache {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SongCacheTests." + UUID().uuidString)
        suiteName = "SongCacheTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let c = SongCache(defaults: defaults, directory: dir)
        c.now = { [weak self] in (self?.fakeDate) ?? Date() }
        c.sizeMB = sizeMB
        cache = c
        return c
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    /// Seed a cached song by "inserting a downloaded file" of `bytes`.
    private func seed(_ c: SongCache, key: String, bytes: Int,
                      ext: String = "m4a") throws {
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        try Data(count: bytes).write(to: src)
        c.insertFile(at: src, key: key, title: "T-" + key, artist: "A",
                     ext: ext)
    }

    private func days(_ n: TimeInterval) -> TimeInterval { n * 86400 }

    // MARK: Hits + persistence

    func testHitAndPersistenceAcrossRelaunch() throws {
        defer { cleanup() }
        let c = makeCache(sizeMB: 100)
        try seed(c, key: "M1", bytes: 1000)

        let hit = c.cachedFileURL(forKey: "M1")
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.pathExtension, "m4a")
        XCTAssertNotNil(c.cachedFileURL(forKey: "M1").map {
            FileManager.default.fileExists(atPath: $0.path)
        })

        // A fresh cache over the same store + directory still finds it.
        let relaunched = SongCache(
            defaults: UserDefaults(suiteName: suiteName)!, directory: dir)
        XCTAssertNotNil(relaunched.cachedFileURL(forKey: "M1"))
    }

    func testExtensionPreserved() throws {
        defer { cleanup() }
        let c = makeCache(sizeMB: 100)
        try seed(c, key: "M2", bytes: 10, ext: "mp3")
        XCTAssertEqual(c.cachedFileURL(forKey: "M2")?.pathExtension, "mp3")
    }

    func testDanglingIndexRowDroppedLazily() throws {
        defer { cleanup() }
        let c = makeCache(sizeMB: 100)
        try seed(c, key: "M3", bytes: 10)
        let url = c.cachedFileURL(forKey: "M3")!
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(c.cachedFileURL(forKey: "M3"))   // dropped
        XCTAssertEqual(c.stats().count, 0)
    }

    // MARK: Stats aging

    func testStatsAgeSplit() throws {
        defer { cleanup() }
        let c = makeCache(sizeMB: 100)
        try seed(c, key: "M1", bytes: 1_000_000)
        XCTAssertEqual(c.stats().agedBytes, 0)

        fakeDate = fakeDate.addingTimeInterval(days(31))
        var s = c.stats()
        XCTAssertEqual(s.agedBytes, 1_000_000)   // over a month old

        c.markPlayed(forKey: "M1")               // playing refreshes age
        s = c.stats()
        XCTAssertEqual(s.agedBytes, 0)
        XCTAssertEqual(s.bytes, 1_000_000)
        XCTAssertEqual(s.count, 1)
    }

    // MARK: Eviction rules

    func testFreshSongsAreNeverEvicted() throws {
        defer { cleanup() }
        let c = makeCache(sizeMB: 2)             // cap 2 MB
        try seed(c, key: "k1", bytes: 1_000_000)
        try seed(c, key: "k2", bytes: 1_000_000)
        try seed(c, key: "k3", bytes: 1_000_000) // pushes over the cap

        // All three are fresh — nothing is allowed to go; the new song is
        // still stored (Spec: evict only once the oldest are month-plus).
        XCTAssertEqual(c.stats().count, 3)
        XCTAssertNotNil(c.cachedFileURL(forKey: "k1"))
        XCTAssertNotNil(c.cachedFileURL(forKey: "k2"))
        XCTAssertNotNil(c.cachedFileURL(forKey: "k3"))
    }

    func testMonthOldEntriesEvictOldestFirst() throws {
        defer { cleanup() }
        let c = makeCache(sizeMB: 2)             // cap 2 MB
        try seed(c, key: "old1", bytes: 1_000_000)
        fakeDate = fakeDate.addingTimeInterval(3600)  // old2 strictly newer
        try seed(c, key: "old2", bytes: 1_000_000)
        fakeDate = fakeDate.addingTimeInterval(days(40))

        try seed(c, key: "new", bytes: 1_000_000) // over cap → must evict

        XCTAssertNil(c.cachedFileURL(forKey: "old1")) // oldest went first
        XCTAssertNotNil(c.cachedFileURL(forKey: "old2")) // fits after 1 evict
        XCTAssertNotNil(c.cachedFileURL(forKey: "new"))

        // The victim's file is really gone from disk, not just the index.
        let leftovers = try FileManager.default.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension != "json" }
        XCTAssertEqual(leftovers.count, 2)
    }

    func testEvictionKeepsGoingWhileOverCapAndOld() throws {
        defer { cleanup() }
        let c = makeCache(sizeMB: 1)             // cap 1 MB
        try seed(c, key: "a", bytes: 1_000_000)
        try seed(c, key: "b", bytes: 1_000_000)   // fresh, over cap, kept
        fakeDate = fakeDate.addingTimeInterval(days(41))
        try seed(c, key: "c", bytes: 1_000_000)
        // Now a and b are month-old; adding c (fresh) is over cap →
        // evict a, still over → evict b (also month-plus). c stays.
        XCTAssertNil(c.cachedFileURL(forKey: "a"))
        XCTAssertNil(c.cachedFileURL(forKey: "b"))
        XCTAssertNotNil(c.cachedFileURL(forKey: "c"))
    }

    // MARK: Tired-removal

    func testRemoveForgetsTheFile() throws {
        defer { cleanup() }
        let c = makeCache(sizeMB: 100)
        try seed(c, key: "M9", bytes: 500)
        c.remove(forKey: "M9")
        XCTAssertNil(c.cachedFileURL(forKey: "M9"))
        XCTAssertEqual(c.stats().count, 0)

        // And the removal survives a relaunch.
        let relaunched = SongCache(
            defaults: UserDefaults(suiteName: suiteName)!, directory: dir)
        XCTAssertNil(relaunched.cachedFileURL(forKey: "M9"))
    }

    // MARK: Keys

    func testKeyPrefersMusicIdThenStableHash() {
        XCTAssertEqual(SongCache.key(forMusicId: "M3423",
                                     title: "x", artist: "y"), "M3423")
        let a = SongCache.key(forMusicId: nil, title: "Song", artist: "Act")
        let b = SongCache.key(forMusicId: "", title: "Song", artist: "Act")
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)   // deterministic fallback (not hashValue)
        XCTAssertNotEqual(a, SongCache.key(forMusicId: nil,
                                           title: "Other", artist: "Act"))
        XCTAssertNil(SongCache.key(forMusicId: nil, title: nil, artist: nil))
    }
}
