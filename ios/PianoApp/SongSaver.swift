//
// SongSaver.swift — download a Pandora stream and transcode it to .m4a
// (AAC) so it can be shared to the Music app / Files.
//
// Note on the Music app: writing directly into the Music library
// requires Apple's restricted `MPMediaLibraryAdditions` entitlement
// (only granted to licensed music apps). The supported path for a
// sideloaded app is: save a standard audio file, then let the user
// share it to Music (or Files). That's what this supports.
//
// The transcode core (`transcode`) is pure (URL → URL) and fully
// unit-testable offline.
//
// Copyright (c) 2025 Spencer Graffunder
// MIT licensed.
//

import AVFoundation
import AudioToolbox
import Foundation

enum SongSaver {
    /// Download `url` into the app's tmp dir and return the local file.
    /// `filename` is the base name (no directory).
    ///
    /// `file://` URLs are read directly (test path); everything else
    /// goes through URLSession.
    static func download(url: URL, filename: String) async throws -> URL {
        let data: Data
        if url.scheme == "file" {
            data = try Data(contentsOf: url)
        } else {
            let (file, _) = try await URLSession.shared
                .download(from: url)
            data = try Data(contentsOf: file)
        }
        let dest = URL.temporaryDirectory
            .appendingPathComponent(filename)
        try data.write(to: dest)
        return dest
    }

    /// Full pipeline: download + transcode to `.m4a`.
    /// Returns the .m4a file URL.
    static func save(url: URL, title: String) async throws -> URL {
        let base = sanitized(title).isEmpty
            ? "song" : sanitized(title)
        let raw = try await download(url: url, filename: base + ".audio")
        defer { try? FileManager.default.removeItem(at: raw) }
        let out = URL.temporaryDirectory
            .appendingPathComponent(base + ".m4a")
        if FileManager.default.fileExists(atPath: out.path) {
            try FileManager.default.removeItem(at: out)
        }
        try await transcode(
            input: raw, output: out,
            preset: AVAssetExportPresetAppleM4A)
        return out
    }

    /// Transcode `input` to `output` using the given AVAssetExportSession
    /// preset name (e.g. `AVAssetExportPresetAppleM4A`).
    /// Pure URL→URL: testable with locally generated audio.
    ///
    /// Tries the export session first (it re-uses the decoder when the
    /// input already carries an MP4 container). That path fails on the
    /// raw, containerless ADTS-AAC stream Pandora actually serves — the
    /// asset loader can't find a "transcodable audio track" in a file with
    /// no container header. When it fails, fall back to `decodeAndEncode`,
    /// which reads the raw stream through AudioToolbox and re-encodes it.
    static func transcode(input: URL, output: URL,
                          preset: String) async throws {
        do {
            try await exportSession(input: input, output: output, preset: preset)
        } catch {
            // The export session may have left a partial file behind;
            // clear it before the fallback so we don't mix outputs.
            try? FileManager.default.removeItem(at: output)
            try await decodeAndEncode(input: input, output: output)
        }
    }

    /// AVAssetExportSession path. Throws if the session can't produce a
    /// valid file (e.g. "no transcodable audio track" on a raw stream).
    private static func exportSession(input: URL, output: URL,
                                      preset: String) async throws {
        let asset = AVURLAsset(url: input)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: preset) else {
            throw NSError(domain: "SongSaver", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                               "Unsupported export preset: \(preset)"])
        }
        session.outputURL = output
        session.outputFileType = .m4a
        await session.export()
        guard session.status == .completed else {
            throw session.error
                ?? NSError(domain: "SongSaver", code: 1,
                           userInfo: [NSLocalizedDescriptionKey:
                                "Transcode failed (status \(session.status.rawValue))"])
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw NSError(domain: "SongSaver", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No output file"])
        }
    }

    /// Decode-and-re-encode fallback for inputs the export session can't
    /// open — most importantly Pandora's raw ADTS-AAC stream, which has no
    /// MP4 container header and so exposes no transcodable track to
    /// AVAssetExportSession.
    ///
    /// Uses AudioToolbox's `ExtAudioFile` (the same low-level path AVPlayer
    /// uses — which is why the song *plays* but the export session refuses
    /// to save it). The source is read and decoded to a canonical PCM buffer
    /// (this half is what understands raw, containerless ADTS), then the PCM
    /// is re-encoded to AAC via `pcmToM4a`.
    static func decodeAndEncode(input: URL, output: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            var src: ExtAudioFileRef?
            var status = ExtAudioFileOpenURL(input as CFURL, &src)
            guard status == noErr, let src else {
                throw error("Couldn't open input (OSStatus \(status))", code: 10)
            }
            defer { ExtAudioFileDispose(src) }

            // Source file format (the actual codec, e.g. raw ADTS-AAC).
            var srcFmt = AudioStreamBasicDescription()
            var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
            status = ExtAudioFileGetProperty(
                src, kExtAudioFileProperty_FileDataFormat, &fmtSize, &srcFmt)
            guard status == noErr else {
                throw error("Couldn't read input format (OSStatus \(status))", code: 10)
            }
            let channels = max(1, Int(srcFmt.mChannelsPerFrame))

            // Canonical 16-bit interleaved PCM at 44.1 kHz.
            let sampleRate: Double = 44100
            var clientFmt = AudioStreamBasicDescription()
            clientFmt.mFormatID = kAudioFormatLinearPCM
            clientFmt.mFormatFlags = kLinearPCMFormatFlagIsPacked
                | kLinearPCMFormatFlagIsSignedInteger
            clientFmt.mSampleRate = sampleRate
            clientFmt.mChannelsPerFrame = UInt32(channels)
            clientFmt.mBitsPerChannel = 16
            clientFmt.mBytesPerChannel = 2
            clientFmt.mBytesPerFrame = UInt32(2 * channels)
            clientFmt.mFramesPerPacket = 1
            let clientSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
            status = ExtAudioFileSetProperty(
                src, kExtAudioFileProperty_ClientDataFormat, clientSize, &clientFmt)
            guard status == noErr else {
                throw error("Couldn't set source format (OSStatus \(status))", code: 10)
            }

            // Decode the whole stream into a PCM buffer.
            let framesPerBlock = 32000
            let bytesPerBlock = framesPerBlock * channels * 2
            var block = [UInt8](repeating: 0, count: bytesPerBlock)
            var pcm = [UInt8]()
            pcm.reserveCapacity(block.count)
            let readStatus = block.withUnsafeMutableBufferPointer { ptr -> OSStatus in
                var abl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(channels),
                        mDataByteSize: UInt32(bytesPerBlock),
                        mData: ptr.baseAddress))
                while true {
                    var frames = UInt32(framesPerBlock)
                    let rs = ExtAudioFileRead(src, &frames, &abl)
                    if frames == 0 { return noErr }   // clean end of stream
                    guard rs == noErr else { return rs }
                    let byteCount = Int(frames) * 2 * channels
                    pcm.append(contentsOf: ptr.prefix(byteCount))
                }
            }
            guard readStatus == noErr else {
                throw error("Decode error (OSStatus \(readStatus))", code: 11)
            }
            try pcmToM4a(pcm: pcm, channels: channels, output: output)
        }.value
    }

    /// Encode interleaved 16-bit signed PCM (44.1 kHz) to a standard MP4-AAC
    /// `.m4a` file at `output`.
    ///
    /// Pure (Data → file): fully unit-testable with locally generated PCM.
    /// This is the encode half of the raw-stream fallback (`decodeAndEncode`
    /// decodes the raw stream to PCM, then hands it to this function).
    static func pcmToM4a(pcm: Data, channels: Int, output: URL) throws {
        let ch = max(1, channels)
        var dst: ExtAudioFileRef?
        var dstFmt = AudioStreamBasicDescription()
        dstFmt.mFormatID = kAudioFormatMPEG4AAC
        dstFmt.mFormatFlags = kMPEG4Object_AAC_Main
        dstFmt.mSampleRate = 44100
        dstFmt.mChannelsPerFrame = UInt32(ch)
        dstFmt.mFramesPerPacket = 1024
        var status = ExtAudioFileCreateWithURL(
            output as CFURL, kAudioFileM4AType, &dstFmt, nil,
            AudioFileFlags.eraseFile.rawValue, &dst)
        guard status == noErr, let dst else {
            throw error("Couldn't create output (OSStatus \(status))", code: 12)
        }
        defer { ExtAudioFileDispose(dst) }

        var clientFmt = AudioStreamBasicDescription()
        clientFmt.mFormatID = kAudioFormatLinearPCM
        clientFmt.mFormatFlags = kLinearPCMFormatFlagIsPacked
            | kLinearPCMFormatFlagIsSignedInteger
        clientFmt.mSampleRate = 44100
        clientFmt.mChannelsPerFrame = UInt32(ch)
        clientFmt.mBitsPerChannel = 16
        clientFmt.mBytesPerChannel = 2
        clientFmt.mBytesPerFrame = UInt32(2 * ch)
        clientFmt.mFramesPerPacket = 1
        let clientSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
        status = ExtAudioFileSetProperty(
            dst, kExtAudioFileProperty_ClientDataFormat, clientSize, &clientFmt)
        guard status == noErr else {
            throw error("Couldn't set output format (OSStatus \(status))", code: 12)
        }

        // Write the PCM in blocks; ExtAudioFile re-encodes it to AAC.
        let bytesPerFrame = 2 * ch
        let blockFrames = 32000
        let blockBytes = blockFrames * bytesPerFrame
        let total = pcm.count
        var offset = 0
        while offset < total {
            let n = min(blockBytes, total - offset)
            let chunk = pcm.subdata(in: offset..<offset + n)
            let frames = UInt32(n / bytesPerFrame)
            let ws = chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> OSStatus in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                var abl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(ch),
                        mDataByteSize: UInt32(n),
                        mData: base))
                return ExtAudioFileWrite(dst, frames, &abl)
            }
            guard ws == noErr else {
                throw error("Encode write error (OSStatus \(ws))", code: 12)
            }
            offset += n
        }
        status = ExtAudioFileFlush(dst, true)
        guard status == noErr else {
            throw error("Finalize error (OSStatus \(status))", code: 12)
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw error("No output file", code: 2)
        }
    }

    private static func error(_ message: String, code: Int) -> NSError {
        NSError(domain: "SongSaver", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// "A B C" → "A-B-C"; strips path-unsafe characters.
    static func sanitized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "*", with: "-")
            .replacingOccurrences(of: "?", with: "-")
            .replacingOccurrences(of: "\"", with: "")
    }
}
