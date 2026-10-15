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
// Why not AVAssetExportSession (the previous implementation)?
// Pandora serves the high-quality stream as HE-AAC (AAC+ with SBR) —
// the same codec AVPlayer decodes fine for playback (see Player.swift).
// But AVAssetExportSession cannot ingest HE-AAC: it fails with
// CoreMedia -3840 ("The operation couldn't be completed"), which is
// exactly what the Save button reported (issue #23). The
// AVAssetReader/AVAssetWriter path below *decodes* any supported
// source (HE-AAC, MP3, plain AAC, PCM) to linear PCM and re-encodes
// to AAC, so it works for every quality tier.
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
        try await transcode(input: raw, output: out)
        return out
    }

    /// Transcode `input` to `output` as AAC in an .m4a container.
    ///
    /// Decodes the source's first audio track (HE-AAC / MP3 / AAC /
    /// PCM — anything AVFoundation can decode) to 16-bit linear PCM at
    /// 44.1 kHz stereo, then re-encodes to AAC 128 kbps in an .m4a.
    /// Pure URL→URL: testable with locally generated audio.
    static func transcode(input: URL, output: URL) async throws {
        let asset = AVURLAsset(url: input)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            // Pandora serves a raw, containerless ADTS-AAC stream. AVURLAsset
            // can't find a track in a file with no MP4 header (issue #40),
            // so AVAssetReader is a dead end. Fall back to the AudioToolbox
            // ExtAudioFile path, which decodes the raw stream the same way
            // AVPlayer does and re-encodes it to a standard .m4a.
            try? FileManager.default.removeItem(at: output)
            try await decodeAndEncode(input: input, output: output)
            return
        }

        // Decode the source (HE-AAC / MP3 / AAC / PCM) to a fixed, known
        // PCM target: 44.1 kHz, stereo, 16-bit. The reader does the decode
        // + resample + channel mixdown to this format, so the writer input
        // is always compatible regardless of the source's native layout.
        let inSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
        ]
        // Re-encode the decoded PCM to AAC (128 kbps) in an .m4a container.
        let outSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track, outputSettings: inSettings)
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        let writer = try AVAssetWriter(
            outputURL: output, fileType: .m4a)
        let writerInput = AVAssetWriterInput(
            mediaType: .audio, outputSettings: outSettings)
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)

        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error
                ?? NSError(domain: "SongSaver", code: 6,
                           userInfo: [NSLocalizedDescriptionKey:
                                "Failed to start transcode"])
        }
        writer.startSession(atSourceTime: .zero)

        while reader.status == .reading {
            guard let sample = readerOutput.copyNextSampleBuffer()
            else { break }
            while !writerInput.isReadyForMoreMediaData {
                if writer.status == .failed { break }  // don't spin forever
                try await Task.sleep(nanoseconds: 10_000_000)  // 10 ms
            }
            guard writerInput.isReadyForMoreMediaData else { break }
            writerInput.append(sample)
        }
        let readerError = reader.status == .failed ? reader.error : nil
        writerInput.markAsFinished()
        await writer.finishWriting()

        if let readerError { throw readerError }
        guard writer.status == .completed else {
            throw writer.error
                ?? NSError(domain: "SongSaver", code: 7,
                           userInfo: [NSLocalizedDescriptionKey:
                                "Transcode failed (status \(writer.status.rawValue))"])
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw NSError(domain: "SongSaver", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No output file"])
        }
    }

    /// Fallback transcoder for files `AVURLAsset` can't enumerate a track in —
    /// most importantly Pandora's raw, containerless ADTS-AAC stream (issue
    /// #40). Opens the input with AudioToolbox's `ExtAudioFile` (the same
    /// low-level decoder `AVPlayer` uses for playback), decodes it to
    /// 16-bit PCM, then re-encodes to AAC via `pcmToM4a`.
    static func decodeAndEncode(input: URL, output: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            var src: ExtAudioFileRef?
            var status = ExtAudioFileOpenURL(input as CFURL, &src)
            guard status == noErr, let src else {
                throw NSError(domain: "SongSaver", code: 10,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Couldn't open input (OSStatus \(status))"])
            }
            defer { ExtAudioFileDispose(src) }

            // Read the source's native format so we know the channel count.
            var srcFmt = AudioStreamBasicDescription()
            var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            status = ExtAudioFileGetProperty(
                src, kExtAudioFileProperty_FileDataFormat, &fmtSize, &srcFmt)
            guard status == noErr else {
                throw NSError(domain: "SongSaver", code: 11,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Couldn't read input format (OSStatus \(status))"])
            }
            let channels = max(1, Int(srcFmt.mChannelsPerFrame))

            // Decode everything to a fixed 16-bit PCM client format.
            var clientFmt = AudioStreamBasicDescription()
            clientFmt.mFormatID = kAudioFormatLinearPCM
            clientFmt.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger
                | kAudioFormatFlagsNativeEndian
                | kLinearPCMFormatFlagIsPacked
            clientFmt.mSampleRate = 44100   // resample here; output ASBD matches
            clientFmt.mChannelsPerFrame = UInt32(channels)
            clientFmt.mBitsPerChannel = 16
            clientFmt.mBytesPerFrame = 2 * UInt32(channels)
            clientFmt.mFramesPerPacket = 1
            clientFmt.mBytesPerPacket = 2 * UInt32(channels)
            fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            status = ExtAudioFileSetProperty(
                src, kExtAudioFileProperty_ClientDataFormat, fmtSize, &clientFmt)
            guard status == noErr else {
                throw NSError(domain: "SongSaver", code: 11,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Couldn't set PCM client format (OSStatus \(status))"])
            }

            // Read the whole stream into one buffer.
            let chunkFrames = 4096
            var pcm = [Int16]()
            pcm.reserveCapacity(Int(clientFmt.mSampleRate) * 2 * channels)
            var readStatus = noErr
            while readStatus == noErr {
                var frameBuf = [Int16](
                    repeating: 0, count: chunkFrames * channels)
                let got = frameBuf.withUnsafeMutableBufferPointer { ptr -> UInt32 in
                    var frames = UInt32(chunkFrames)
                    var abl = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: UInt32(channels),
                            mDataByteSize:
                                UInt32(chunkFrames * channels * 2),
                            mData: ptr.baseAddress))
                    let rs = ExtAudioFileRead(src, &frames, &abl)
                    if frames == 0 { return 0 }
                    guard rs == noErr else { return 0 }
                    return frames
                }
                if got == 0 { break }
                for i in 0..<(Int(got) * channels) {
                    pcm.append(frameBuf[i])
                }
            }
            guard !pcm.isEmpty else {
                throw NSError(domain: "SongSaver", code: 13,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Input had no audio to decode"])
            }
            try pcmToM4a(pcm: pcm, channels: channels, output: output)
        }.value
    }

    /// Re-encode raw interleaved 16-bit PCM to AAC in an `.m4a` container via
    /// `ExtAudioFile`. Pure file I/O; testable offline.
    static func pcmToM4a(pcm: [Int16], channels: Int, output: URL) throws {
        let ch = max(1, channels)
        var dst: ExtAudioFileRef?
        var dstFmt = AudioStreamBasicDescription()
        dstFmt.mFormatID = kAudioFormatMPEG4AAC
        // AAC-LC object type. kMPEG4Object_AAC_LC (MPEG4ObjectID = 2) is not
        // exported by the iOS AudioToolbox Swift module, so use the literal
        // value from CoreAudioBaseTypes.h.
        dstFmt.mFormatFlags = 2
        dstFmt.mSampleRate = 44100
        dstFmt.mChannelsPerFrame = UInt32(ch)
        dstFmt.mBytesPerFrame = 0
        dstFmt.mFramesPerPacket = 0
        dstFmt.mBytesPerPacket = 0
        dstFmt.mBitsPerChannel = 0
        let status = ExtAudioFileCreateWithURL(
            output as CFURL, kAudioFileM4AType, &dstFmt, nil,
            AudioFileFlags.eraseFile.rawValue, &dst)
        guard status == noErr, let dst else {
            throw NSError(domain: "SongSaver", code: 12,
                userInfo: [NSLocalizedDescriptionKey:
                    "Couldn't create .m4a output (OSStatus \(status))"])
        }
        defer { ExtAudioFileDispose(dst) }

        // The file format is AAC (dstFmt), but what we feed in is PCM —
        // declare the client (input) format as interleaved 16-bit PCM so
        // ExtAudioFileWrite encodes it to AAC.
        var clientFmt = AudioStreamBasicDescription()
        clientFmt.mFormatID = kAudioFormatLinearPCM
        clientFmt.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger
            | kAudioFormatFlagsNativeEndian
            | kLinearPCMFormatFlagIsPacked
        clientFmt.mSampleRate = 44100
        clientFmt.mChannelsPerFrame = UInt32(ch)
        clientFmt.mBitsPerChannel = 16
        clientFmt.mBytesPerFrame = 2 * UInt32(ch)
        clientFmt.mFramesPerPacket = 1
        clientFmt.mBytesPerPacket = 2 * UInt32(ch)
        var cfSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let cStatus = ExtAudioFileSetProperty(
            dst, kExtAudioFileProperty_ClientDataFormat, cfSize, &clientFmt)
        guard cStatus == noErr else {
            throw NSError(domain: "SongSaver", code: 12,
                userInfo: [NSLocalizedDescriptionKey:
                    "Couldn't set PCM client format (OSStatus \(cStatus))"])
        }

        // Feed the PCM through the writer in interleaved 16-bit chunks.
        let chunkFrames = 4096
        var frameIdx = 0
        while frameIdx < pcm.count / ch {
            let n = min(chunkFrames, pcm.count / ch - frameIdx)
            var slice = pcm[frameIdx * ch..<(frameIdx + n) * ch]
            let rs = slice.withUnsafeMutableBufferPointer { ptr -> OSStatus in
                var abl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(ch),
                        mDataByteSize: UInt32(n * ch * 2),
                        mData: ptr.baseAddress))
                return ExtAudioFileWrite(dst, UInt32(n), &abl)
            }
            if rs != noErr {
                throw NSError(domain: "SongSaver", code: 14,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Failed writing .m4a (OSStatus \(rs))"])
            }
            frameIdx += n
        }
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
