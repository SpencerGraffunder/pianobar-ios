//
// MediaSessionTests.swift — unit tests for the Now Playing / remote
// command layer (MediaSession) and the song-save pipeline (SongSaver).
//
// All tests are offline: a recording fake model + fake player stand in
// for AppModel/Player, and audio is generated locally with AVAudioFile.
//
// Copyright (c) 2025 Spencer Graffunder
// MIT licensed.
//

import AVFoundation
import Foundation
import MediaPlayer
import XCTest

@testable import PianoApp

// MARK: - Fakes

private final class FakePlayer: PlayerLike {
    var isPlaying = false
    /// What "actively playing" reports (drives the Now Playing icon).
    var activelyPlaying = false
    var playCount = 0
    var pauseCount = 0

    func play() { isPlaying = true; activelyPlaying = true; playCount += 1 }
    func pause() { isPlaying = false; activelyPlaying = false; pauseCount += 1 }
}

@MainActor
private final class FakeModel: MediaSessionModel {
    let player = FakePlayer()
    var npTitle: String? = "Song Title"
    var npArtist: String? = "Artist Name"
    var npAlbum: String? = "Album Name"
    var npDuration: Double = 200
    var npElapsed: Double = 10

    var playCount = 0
    var pauseCount = 0
    var nextCount = 0
    var prevCount = 0
    var canResume = true
    var isPlayingNow: Bool { player.isPlaying }

    func npActivelyPlaying() -> Bool { player.activelyPlaying }

    func modelPlay() {
        player.play()
        playCount += 1
    }
    func modelPause() {
        player.pause()
        pauseCount += 1
    }
    func modelNext() { nextCount += 1 }
    func modelPrevious() { prevCount += 1 }
    func resumable() -> Bool { canResume }
}

// MARK: - Now Playing info

final class NowPlayingTests: XCTestCase {
    @MainActor
    private func makeSession() -> (MediaSession, FakeModel) {
        let model = FakeModel()
        return (MediaSession(model: model), model)
    }

    @MainActor
    func testNowPlayingInfoContainsSongMetadataAndState() {
        let (session, model) = makeSession()
        session.updateNowPlaying(
            title: model.npTitle, artist: model.npArtist, album: model.npAlbum,
            duration: model.npDuration, elapsed: model.npElapsed,
            playing: true, activelyPlaying: true)

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(info?[MPMediaItemPropertyTitle] as? String, "Song Title")
        XCTAssertEqual(info?[MPMediaItemPropertyArtist] as? String, "Artist Name")
        XCTAssertEqual(info?[MPMediaItemPropertyAlbumTitle] as? String, "Album Name")
        XCTAssertEqual(info?[MPMediaItemPropertyPlaybackDuration] as? Double, 200)
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 10)
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.0)
    }

    /// The transport icon follows `activelyPlaying`, not the intent flag.
    /// This is the fix for the Control Center icon flickering
    /// play→pause→play while a stream is still buffering: while the user
    /// has hit Play (`playing == true`) but AVPlayer is still buffering
    /// (`activelyPlaying == false`), the icon must read "paused" — and
    /// only flip to "playing" once audio is actually flowing.
    @MainActor
    func testTransportIconReflectsActivelyPlayingNotIntent() {
        let (session, model) = makeSession()
        // User pressed play, but the stream is still buffering.
        session.updateNowPlaying(
            title: model.npTitle, artist: model.npArtist, album: model.npAlbum,
            duration: model.npDuration, elapsed: model.npElapsed,
            playing: true, activelyPlaying: false)
        let buffering = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(buffering?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0.0)

        // Audio is now flowing.
        session.updateNowPlaying(
            title: model.npTitle, artist: model.npArtist, album: model.npAlbum,
            duration: model.npDuration, elapsed: model.npElapsed,
            playing: true, activelyPlaying: true)
        let playing = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(playing?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.0)
    }

    @MainActor
    func testPausedStateReportsZeroPlaybackRate() {
        let (session, model) = makeSession()
        session.updateNowPlaying(
            title: model.npTitle, artist: model.npArtist, album: model.npAlbum,
            duration: model.npDuration, elapsed: model.npElapsed,
            playing: false, activelyPlaying: false)

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0.0)
    }

    @MainActor
    func testClearNowPlayingResetsInfo() {
        let (session, _) = makeSession()
        session.updateNowPlaying(
            title: "x", artist: nil, album: nil,
            duration: 0, elapsed: 0, playing: true, activelyPlaying: true)
        XCTAssertNotNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        session.clearNowPlaying()
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }
}

// MARK: - Remote command wiring

final class RemoteCommandTests: XCTestCase {
    @MainActor
    func testAllFiveTransportCommandsReachTheModel() {
        let model = FakeModel()
        let session = MediaSession(model: model)

        session.handle(.play)
        session.handle(.pause)
        session.handle(.toggle)   // paused → plays
        session.handle(.next)
        session.handle(.previous)

        XCTAssertEqual(model.playCount, 2)   // play + toggle(while paused)
        XCTAssertEqual(model.pauseCount, 1)  // pause
        XCTAssertEqual(model.nextCount, 1)
        XCTAssertEqual(model.prevCount, 1)
    }

    @MainActor
    func testTogglePausesWhilePlayingAndPlaysWhilePaused() {
        let model = FakeModel()
        let session = MediaSession(model: model)

        model.player.isPlaying = true
        session.handle(.toggle)
        XCTAssertTrue(model.player.pauseCount >= 1)

        model.player.isPlaying = false
        model.player.pauseCount = 0
        session.handle(.toggle)
        XCTAssertTrue(model.player.playCount >= 1)
    }

    @MainActor
    func testCommandHandlersAreRegisteredOnSharedCenter() {
        _ = MediaSession(model: FakeModel())
        // Registration enables the command on the shared center.
        let c = MPRemoteCommandCenter.shared()
        XCTAssertTrue(c.playCommand.isEnabled)
        XCTAssertTrue(c.pauseCommand.isEnabled)
        XCTAssertTrue(c.togglePlayPauseCommand.isEnabled)
        XCTAssertTrue(c.nextTrackCommand.isEnabled)
        XCTAssertTrue(c.previousTrackCommand.isEnabled)
    }
}

// MARK: - Interruptions + route changes

final class AudioSessionEventTests: XCTestCase {
    @MainActor
    func testInterruptionBeginsPausesPlayback() {
        let model = FakeModel()
        model.player.isPlaying = true
        let session = MediaSession(model: model)
        let before = model.player.pauseCount
        session.simulateInterruption(began: true, shouldResume: false)
        XCTAssertEqual(model.player.pauseCount, before + 1)
    }

    @MainActor
    func testInterruptionEndsResumesWhenAllowed() {
        let model = FakeModel()
        model.player.isPlaying = false
        let session = MediaSession(model: model)
        session.simulateInterruption(began: false, shouldResume: true)
        XCTAssertTrue(model.player.isPlaying)
    }

    @MainActor
    func testInterruptionEndsDoesNotResumeWhenNotAllowed() {
        let model = FakeModel()
        model.player.isPlaying = false
        let session = MediaSession(model: model)
        session.simulateInterruption(began: false, shouldResume: false)
        XCTAssertFalse(model.player.isPlaying)
    }

    @MainActor
    func testRouteChangeOldDeviceUnavailablePauses() {
        let model = FakeModel()
        model.player.isPlaying = true
        let session = MediaSession(model: model)
        let before = model.player.pauseCount
        session.simulateRouteChange(
            reason: .oldDeviceUnavailable)
        XCTAssertEqual(model.player.pauseCount, before + 1)
    }
}

// MARK: - Song saving (download/transcode pipeline)

final class SongSaverTests: XCTestCase {
    /// Generate a small audio file locally (no network) for transcode tests.
    ///
    /// Recipe (verified on macOS 26.6 + iOS 26.5 simulator, Xcode 26.6):
    /// int16-interleaved CAF. The earlier float32 variant
    /// (standardFormatWithSampleRate + floatChannelData) wrote a file that
    /// AVAssetExportSession refused to open ("asset has no playable formats");
    /// `AVAudioFormat(commonFormat: .pcmFormatInt16, …)` is the one that
    /// reliably loads. Buffer is filled against `file.processingFormat`
    /// (float32) and AVAudioFile converts to int16 on write.
    private func makeLocalAudioFile(seconds: Double = 0.5) throws -> URL {
        let url = URL.temporaryDirectory
            .appendingPathComponent("pianobar-test-input-\(UUID().uuidString).caf")
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                   sampleRate: 44100, channels: 2,
                                   interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 44100)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                   frameCapacity: frames)!
        buf.frameLength = frames
        if let ch0 = buf.floatChannelData?[0] {
            for i in 0..<Int(frames) {
                ch0[i] = Float(sin(Double(i) / 441.0 * .pi * 2 * 440)) * 0.5
            }
        }
        if let ch1 = buf.floatChannelData?[1] {
            for i in 0..<Int(frames) { ch1[i] = 0 }
        }
        try file.write(from: buf)
        if #available(iOS 18.0, *) { file.close() }  // finalize container header
        return url
    }

    func testTranscodeProducesPlayableM4A() async throws {
        let input = try makeLocalAudioFile()
        defer { try? FileManager.default.removeItem(at: input) }
        let output = URL.temporaryDirectory
            .appendingPathComponent("pianobar-test-out-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: output) }

        try await SongSaver.transcode(input: input, output: output)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0)
        let size = try FileManager.default
            .attributesOfItem(atPath: output.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 1000)
    }

    /// Regression for issue #23: the real failure was the *encoded* source
    /// path — Pandora streams arrive as AAC/HE-AAC, which the old
    /// AVAssetExportSession rejected ("The operation couldn't be
    /// completed"). This encodes a source file with AVAudioFile (AAC in
    /// .m4a), then transcodes it through the new reader/writer pipeline,
    /// proving decode → re-encode works for compressed (not just PCM) input.
    func testTranscodeFromEncodedAACSource() async throws {
        // 1. Make a PCM source.
        let pcm = try makeLocalAudioFile(seconds: 0.3)
        defer { try? FileManager.default.removeItem(at: pcm) }

        // 2. Encode it to AAC/.m4a with AVAudioFile (mirrors what
        //    Pandora's CDN serves).
        let aac = URL.temporaryDirectory
            .appendingPathComponent("pianobar-aac-src-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: aac) }
        try await Task.detached(priority: .userInitiated) {
            let inFile = try AVAudioFile(forReading: pcm)
            let outFile = try AVAudioFile(forWriting: aac, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 64_000,
            ])
            let frames = AVAudioFrameCount(0.3 * 44100)
            let buf = AVAudioPCMBuffer(
                pcmFormat: inFile.processingFormat, frameCapacity: frames)!
            buf.frameLength = frames
            try inFile.read(into: buf)
            try outFile.write(from: buf)
            if #available(iOS 18.0, *) { inFile.close(); outFile.close() }
        }.value

        // 3. Transcode it — the exact shape of the production pipeline.
        let output = URL.temporaryDirectory
            .appendingPathComponent("pianobar-test-out-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: output) }
        try await SongSaver.transcode(input: aac, output: output)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0.1)
        let size = try FileManager.default
            .attributesOfItem(atPath: output.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 1000)
    }

    func testTranscodeFailureThrows() async {
        let missing = URL.temporaryDirectory
            .appendingPathComponent("definitely-missing-\(UUID().uuidString).pcm")
        let output = URL.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString).m4a")
        do {
            _ = try await SongSaver.transcode(input: missing, output: output)
            XCTFail("expected transcode to throw")
        } catch {
            // A real transcode failure: the error carries a domain
            // (Cocoa / AVFoundation) and no output file is produced.
            XCTAssertFalse((error as NSError).domain.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testSanitizedFilenameStripsUnsafeChars() {
        // Replacements: [ / : * ? ] → "-",  "\"" → removed.
        XCTAssertEqual(SongSaver.sanitized("a/b: c*d?e\"f"),
                       "a-b- c-d-ef")
        XCTAssertEqual(SongSaver.sanitized("  padded  "), "padded")
        XCTAssertTrue(SongSaver.sanitized("   ").isEmpty)
    }

    /// Offline download test: a `file://` URL through the same
    /// URLSession.download path used for real streams.
    func testDownloadViaFileURL() async throws {
        let src = URL.temporaryDirectory
            .appendingPathComponent("dl-src-\(UUID().uuidString).bin")
        try Data(repeating: 7, count: 4096).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let dest = try await SongSaver.download(
            url: src, filename: "dl-dest.bin")
        defer { try? FileManager.default.removeItem(at: dest) }

        XCTAssertEqual(try Data(contentsOf: dest).count, 4096)
    }
}
