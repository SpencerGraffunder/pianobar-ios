//
// PianoClient.swift — Swift client over the unmodified pianobar C core
// (src/libpiano). Mirrors the call loop of the original terminal UI
// (BarUiPianoCall in src/ui.c):
//
//   do {
//     PianoRequest(handle, &req, type)
//     HTTP POST (URLSession)  →  req.responseData
//     PianoResponse(handle, &req)
//   } while (PIANO_RET_CONTINUE_REQUEST)
//
// Small C helpers in ios/Glue/piano_ios.c bridge the awkward parts
// (fixed-size urlPath buffer, responseData ownership).
//
// Copyright (c) 2025 Spencer Graffunder
// MIT licensed.
//

import Foundation

// MARK: - Errors

enum PianoError: LocalizedError {
    /// A pianobar C-core error (`PianoReturn_t`).
    case piano(PianoReturn_t)
    /// An HTTP/URLSession error.
    case network(String)
    /// Malformed or missing data.
    case badData(String)

    var errorDescription: String? {
        switch self {
        case .piano(let rc):
            if let p = PianoErrorToStr(rc) {
                return String(cString: p)
            }
            return "Pianobar error \(Int(rc.rawValue))"
        case .network(let s):
            return "Network error: \(s)"
        case .badData(let s):
            return "Bad data: \(s)"
        }
    }
}

// MARK: - Models

private func cstr(_ p: UnsafeMutablePointer<CChar>?) -> String? {
    guard let p else { return nil }
    return String(cString: p)
}

/// A Pandora station. The C struct is owned by the core (handle->stations).
struct Station: Identifiable, Hashable {
    let raw: UnsafeMutablePointer<PianoStation>

    var cId: String? { cstr(raw.pointee.id) }
    var name: String? { cstr(raw.pointee.name) }
    var seedId: String? { cstr(raw.pointee.seedId) }
    var isCreator: Bool { raw.pointee.isCreator != 0 }
    var isQuickMix: Bool { raw.pointee.isQuickMix != 0 }
    var useQuickMix: Bool { raw.pointee.useQuickMix != 0 }

    /// Stable identifier for UI selection / Identifiable.
    var stableId: String { cId ?? name ?? "\(raw)" }
    var id: String { stableId }

    static func == (l: Station, r: Station) -> Bool { l.raw == r.raw }
    func hash(into h: inout Hasher) { h.combine(UnsafeRawPointer(raw)) }
}

/// A song from the current playlist.
///
/// A **value copy**, safe to store: the fields are read out of the C
/// `PianoSong_t` at creation time, so the value outlives the C playlist.
/// This matters because every `getPlaylist` call frees the *previous*
/// C playlist (the core owns it), so keeping C pointers into a playlist
/// is a use-after-free the instant the next playlist is fetched — the
/// exact crash from switching stations mid-playback and tapping Next.
///
/// The C core only reads `stationId` and `trackToken` from a song
/// (rate / tired / explain / bookmark), and both are copied here.
struct Song: Identifiable, Hashable {
    var artist: String?
    var title: String?
    var album: String?
    var audioUrl: String?
    var musicId: String?
    var trackToken: String?
    var stationId: String?
    var seedId: String?
    var detailUrl: String?
    var coverArt: String?
    var length: UInt32
    var rating: PianoSongRating_t
    var audioFormat: PianoAudioFormat_t

    var stableId: String { trackToken ?? musicId ?? title ?? "song" }
    var id: String { stableId }

    init(_ s: PianoSong) {
        artist = cstr(s.artist)
        title = cstr(s.title)
        album = cstr(s.album)
        audioUrl = cstr(s.audioUrl)
        musicId = cstr(s.musicId)
        trackToken = cstr(s.trackToken)
        stationId = cstr(s.stationId)
        seedId = cstr(s.seedId)
        detailUrl = cstr(s.detailUrl)
        coverArt = cstr(s.coverArt)
        length = s.length
        rating = s.rating
        audioFormat = s.audioFormat
    }
}

/// A search-result artist (value copy; safe to store).
struct SearchArtist: Identifiable, Hashable {
    let name: String
    let musicId: String
    var id: String { musicId }
}

/// A search-result song (value copy; safe to store).
struct SearchSong: Identifiable, Hashable {
    let title: String
    let artist: String
    let musicId: String
    var id: String { musicId }
}

struct SearchResult {
    var artists: [SearchArtist] = []
    var songs: [SearchSong] = []
    var isEmpty: Bool { artists.isEmpty && songs.isEmpty }
}

// MARK: - Client

/// One authenticated (or not yet authenticated) pianobar session.
///
/// All methods are `async` (they perform network I/O). Serialize access:
/// the UI model runs one action at a time.
final class PianoClient {
    private let handle: UnsafeMutablePointer<PianoHandle>
    private let username: String
    private let password: String

    /// Playlist from the last getPlaylist; owned by us, freed when
    /// replaced or in deinit.
    private var currentPlaylist: UnsafeMutablePointer<PianoSong>?

    /// Defaults from src/settings.c (the "android" partner).
    ///
    /// `device` MUST be "android-generic" (pianobar's default, settings.c).
    /// Pandora's backend returns HTTP 504 ("upstream request timeout") for
    /// partnerLogin when deviceModel is the bare "android" — verified
    /// deterministically against tuner.pandora.com.
    private static let partnerUser = "android"
    private static let partnerPassword = "AC7IBG09A3DTSYM4R41UJWL07VLN8JI7"
    private static let device = "android-generic"
    private static let inkey = "R=U!LH$O2B#"
    private static let outkey = "6#26FRL$ZWD"
    private static let rpcHost = "tuner.pandora.com"
    private static let rpcTlsPort = "443"

    /// Create a client. Throws if the C core fails to initialize.
    init(username: String, password: String) throws {
        self.username = username
        self.password = password
        let h = UnsafeMutablePointer<PianoHandle>.allocate(capacity: 1)
        let rc = PianoInit(
            h,
            Self.partnerUser,
            Self.partnerPassword,
            Self.device,
            Self.inkey,
            Self.outkey)
        guard rc == PIANO_RET_OK else {
            h.deallocate()
            throw PianoError.piano(rc)
        }
        handle = h
    }

    deinit {
        if let pl = currentPlaylist {
            PianoDestroyPlaylist(pl)
            currentPlaylist = nil
        }
        PianoDestroy(handle)
        handle.deallocate()
    }

    // MARK: - State

    var listenerId: String? { cstr(handle.pointee.user.listenerId) }
    var userAuthToken: String? { cstr(handle.pointee.user.authToken) }
    var isLoggedIn: Bool { handle.pointee.user.authToken != nil }

    // MARK: - Small helpers

    /// Heap copy of a Swift String as a NUL-terminated C string.
    /// Caller must `free()` the result.
    private func cCopy(_ s: String) -> UnsafeMutablePointer<CChar> {
        let bytes = Array(s.utf8CString)
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
        bytes.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            if let base = src.baseAddress {
                memcpy(buf, base, bytes.count)
            }
        }
        return buf
    }

    /// Build a transient C `PianoSong_t` from a `Song` value, providing
    /// exactly the fields the core reads for a song (stationId + trackToken,
    /// used by rate / tired / explain / bookmark). The caller owns the result
    /// and releases it with `freeCSong` once the request has finished.
    private func makeCSong(_ song: Song) -> UnsafeMutablePointer<PianoSong> {
        makeCSong(trackToken: song.trackToken, stationId: song.stationId)
    }

    /// Token-based variant used by the offline command queue: at send time
    /// the original `Song` struct may be long gone, but the tokens captured
    /// when the command was queued are exactly what the core reads.
    private func makeCSong(trackToken: String?, stationId: String?)
        -> UnsafeMutablePointer<PianoSong>
    {
        let s = UnsafeMutablePointer<PianoSong>.allocate(capacity: 1)
        memset(s, 0, MemoryLayout<PianoSong>.stride)
        if let t = trackToken { s.pointee.trackToken = cCopy(t) }
        if let sid = stationId { s.pointee.stationId = cCopy(sid) }
        return s
    }

    /// Release a `PianoSong_t` made by `makeCSong`.
    private func freeCSong(_ s: UnsafeMutablePointer<PianoSong>) {
        if let t = s.pointee.trackToken { free(t) }
        if let sid = s.pointee.stationId { free(sid) }
        s.deallocate()
    }

    /// Run one core request with a heap-allocated data struct.
    /// `setup` fills the struct; optional `finish` reads it after the
    /// call (before it is freed).
    private func runData<T>(
        _ type: PianoRequestType_t,
        timeout: TimeInterval = 30,
        attempts: Int = 3,
        setup: (UnsafeMutablePointer<T>) -> Void,
        finish: ((UnsafeMutablePointer<T>) -> Void)? = nil
    ) async throws {
        let d = UnsafeMutablePointer<T>.allocate(capacity: 1)
        memset(d, 0, MemoryLayout<T>.stride)
        setup(d)
        do {
            try await call(type, data: UnsafeMutableRawPointer(d),
                           timeout: timeout, attempts: attempts)
            finish?(d)
        } catch {
            d.deallocate()
            throw error
        }
        d.deallocate()
    }

    /// Free `req.responseData` (core owns it after PianoResponse) —
    /// PianoDestroyRequest frees postData and zeroes the struct.
    private func cleanupRequest(_ req: inout PianoRequest) {
        PianoDestroyRequest(&req)
    }

    // MARK: - Generic call loop (mirrors BarUiPianoCall in ui.c)

    private func call(_ type: PianoRequestType_t,
                      data: UnsafeMutableRawPointer?,
                      timeout: TimeInterval = 30,
                      attempts: Int = 3) async throws {
        var steps = 0
        var didReauth = false
        var pRet: PianoReturn_t = PIANO_RET_OK

        repeat {
            steps += 1
            precondition(steps <= 8, "pianobar request loop runaway")

            var req = PianoRequest()
            req.data = data

            do {
                pRet = PianoRequest(handle, &req, type)
                if pRet != PIANO_RET_OK {
                    throw PianoError.piano(pRet)
                }

                // Read the URL path (fixed C array) via the glue helper.
                guard let pathC = PianoIosUrlPathCopy(&req) else {
                    throw PianoError.badData("no URL path")
                }
                defer { free(pathC) }
                let path = String(cString: pathC)

                let body = try await performHTTP(
                    path: path, secure: req.secure, postData: req.postData,
                    timeout: timeout, attempts: attempts)

                // Store the body NUL-terminated (glue strdups it).
                var buf = [UInt8](body)
                buf.append(0)
                buf.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        PianoIosSetResponseData(
                            &req, base.assumingMemoryBound(to: CChar.self))
                    }
                }

                pRet = PianoResponse(handle, &req)
            } catch {
                cleanupRequest(&req)
                throw error
            }
            cleanupRequest(&req)

            // Reauthenticate once on expired token (as ui.c does).
            if pRet == PIANO_RET_P_INVALID_AUTH_TOKEN &&
                    type != PIANO_REQUEST_LOGIN && !didReauth {
                didReauth = true
                try await login()
                pRet = PIANO_RET_CONTINUE_REQUEST
            }
        } while pRet == PIANO_RET_CONTINUE_REQUEST

        guard pRet == PIANO_RET_OK else { throw PianoError.piano(pRet) }
    }

    /// Perform the HTTP POST and return the response body.
    /// Mirrors BarPianoHttpRequest in ui.c.
    ///
    /// Retries transient server errors (502/503/504) up to 3 times with a
    /// short backoff. Pandora's gateway is known to return intermittent
    /// 504 "upstream request timeout" (see the deviceModel note above and
    /// the regression guard in PianoNetworkTests) — a single flaky 504
    /// should not hard-fail the request. 4xx and other non-transient
    /// failures throw immediately.
    /// `timeout`/`attempts` shrink for queued background sends
    /// (`quick: true`): one attempt, shorter timeout, so a dead network
    /// fails fast and releases the gate for interactive actions.
    private func performHTTP(path: String, secure: Bool,
                             postData: UnsafeMutablePointer<CChar>?,
                             timeout: TimeInterval = 30,
                             attempts: Int = 3)
        async throws -> Data
    {
        let scheme = secure ? "https" : "http"
        let port = secure ? Self.rpcTlsPort : "80"
        guard let url = URL(string: "\(scheme)://\(Self.rpcHost):\(port)\(path)")
        else {
            throw PianoError.badData(
                "bad URL: \(scheme)://\(Self.rpcHost):\(port)\(path)")
        }

        var http = URLRequest(url: url, timeoutInterval: timeout)
        http.httpMethod = "POST"
        http.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        http.setValue("pianobar-ios/1.0", forHTTPHeaderField: "User-Agent")
        if let post = postData {
            let len = Int(strlen(post))
            http.httpBody = Data(bytes: post, count: len)
        }

        // Diagnostic: log the exact outgoing request (URL + headers + size).
        let reqHdrs = (http.allHTTPHeaderFields ?? [:])
            .map { "\($0.key): \($0.value)" }.sorted().joined(separator: " | ")
        let bodyLen = http.httpBody?.count ?? 0
        NSLog("PianoHTTP REQ URL=%@ | hdrs=[%@] | bodyBytes=%d",
              url.absoluteString, reqHdrs, Int32(bodyLen))

        let transient = Set([502, 503, 504])
        let maxAttempts = max(1, attempts)
        for attempt in 1...maxAttempts {
            let (data, response) = try await URLSession.shared.data(for: http)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let respHdrs = ((response as? HTTPURLResponse)?.allHeaderFields as? [String: Any] ?? [:])
            let respHdrsS = respHdrs.map { "\($0.key): \($0.value)" }.sorted().joined(separator: " | ")
            let bodyS = String((String(data: data, encoding: .utf8) ?? "(binary \(data.count)B)").prefix(400))
            NSLog("PianoHTTP RESP attempt=%d | status=%d | hdrs=[%@] | body=%@",
                  Int32(attempt), Int32(status), respHdrsS, bodyS)
            if (200..<300).contains(status) {
                return data
            }
            if transient.contains(status) && attempt < maxAttempts {
                NSLog("PianoHTTP transient HTTP %d — retrying (backoff)", status)
                try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                continue
            }
            throw PianoError.network("HTTP \(status)")
        }
        // Unreachable: the loop either returns or throws on each pass.
        fatalError("performHTTP: exhausted retry loop without returning")
    }

    // MARK: - API

    /// Log in (two-step: partnerLogin → userLogin, driven by
    /// PIANO_RET_CONTINUE_REQUEST).
    func login() async throws {
        let u = cCopy(username)
        let p = cCopy(password)
        defer {
            free(u)
            free(p)
        }
        try await runData(PIANO_REQUEST_LOGIN) {
            (d: UnsafeMutablePointer<PianoRequestDataLogin_t>) in
            d.pointee.user = u
            d.pointee.password = p
            d.pointee.step = 0
        }
    }

    /// Refresh the station list (result stored on the handle).
    func getStations() async throws {
        try await call(PIANO_REQUEST_GET_STATIONS, data: nil)
    }

    /// All stations currently on the handle.
    func stations() -> [Station] {
        var result: [Station] = []
        var cur: UnsafeMutablePointer<PianoStation>? = handle.pointee.stations
        while let s = cur {
            result.append(Station(raw: s))
            cur = s.pointee.head.next.map {
                UnsafeMutableRawPointer($0)
                    .assumingMemoryBound(to: PianoStation.self)
            }
        }
        return result
    }

    /// Find a station by id (or nil).
    func station(id: String) -> Station? {
        id.withCString { idc -> Station? in
            guard let s = PianoFindStationById(handle.pointee.stations, idc)
            else { return nil }
            return Station(raw: s)
        }
    }

    /// Get the next playlist for a station (typically 4 songs).
    /// The returned songs stay valid until the next getPlaylist call
    /// (or client deinit) on this client.
    func getPlaylist(station: Station) async throws -> [Song] {
        if let old = currentPlaylist {
            PianoDestroyPlaylist(old)
            currentPlaylist = nil
        }
        var playlist: UnsafeMutablePointer<PianoSong>?
        try await runData(
            PIANO_REQUEST_GET_PLAYLIST,
            setup: { (d: UnsafeMutablePointer<PianoRequestDataGetPlaylist_t>) in
                d.pointee.station = station.raw
                d.pointee.quality = PIANO_AQ_HIGH
                d.pointee.retPlaylist = nil
            },
            finish: { (d: UnsafeMutablePointer<PianoRequestDataGetPlaylist_t>) in
                playlist = d.pointee.retPlaylist
            })
        currentPlaylist = playlist
        var result: [Song] = []
        var cur = playlist
        while let s = cur {
            result.append(Song(s.pointee))
            cur = s.pointee.head.next.map {
                UnsafeMutableRawPointer($0).assumingMemoryBound(to: PianoSong.self)
            }
        }
        return result
    }

    /// Love / ban the current song.
    func rateSong(_ song: Song, rating: PianoSongRating_t) async throws {
        try await rateSong(trackToken: song.trackToken,
                           stationId: song.stationId, rating: rating)
    }

    /// Rate by token (used by the offline command queue). `quick: true`
    /// uses one short HTTP attempt — a queued send must not hog the gate.
    func rateSong(trackToken: String?, stationId: String?,
                  rating: PianoSongRating_t, quick: Bool = false) async throws {
        let cs = makeCSong(trackToken: trackToken, stationId: stationId)
        defer { freeCSong(cs) }
        try await runData(PIANO_REQUEST_RATE_SONG,
                          timeout: quick ? 12 : 30,
                          attempts: quick ? 1 : 3) {
            (d: UnsafeMutablePointer<PianoRequestDataRateSong_t>) in
            d.pointee.song = cs
            d.pointee.rating = rating
        }
    }

    /// Mark the current song as "tired" (sleep for a month).
    func markTired(_ song: Song) async throws {
        try await markTired(trackToken: song.trackToken,
                            stationId: song.stationId)
    }

    /// Tired by token (used by the offline command queue).
    func markTired(trackToken: String?, stationId: String?,
                   quick: Bool = false) async throws {
        let cs = makeCSong(trackToken: trackToken, stationId: stationId)
        defer { freeCSong(cs) }
        try await call(PIANO_REQUEST_ADD_TIRED_SONG,
                       data: UnsafeMutableRawPointer(cs),
                       timeout: quick ? 12 : 30,
                       attempts: quick ? 1 : 3)
    }

    /// Search for artists and songs. Results are copied to Swift values
    /// and the C list freed, so the result is safe to store.
    func search(_ query: String) async throws -> SearchResult {
        let q = cCopy(query)
        defer { free(q) }
        var result = SearchResult()
        try await runData(
            PIANO_REQUEST_SEARCH,
            setup: { (d: UnsafeMutablePointer<PianoRequestDataSearch_t>) in
                d.pointee.searchStr = q
                d.pointee.searchResult = PianoSearchResult()
            },
            finish: { (d: UnsafeMutablePointer<PianoRequestDataSearch_t>) in
                var acur: UnsafeMutablePointer<PianoArtist>? =
                    d.pointee.searchResult.artists
                while let a = acur {
                    result.artists.append(SearchArtist(
                        name: cstr(a.pointee.name) ?? "?",
                        musicId: cstr(a.pointee.musicId) ?? ""))
                    acur = a.pointee.head.next.map {
                        UnsafeMutableRawPointer($0)
                            .assumingMemoryBound(to: PianoArtist.self)
                    }
                }
                var scur: UnsafeMutablePointer<PianoSong>? =
                    d.pointee.searchResult.songs
                while let s = scur {
                    result.songs.append(SearchSong(
                        title: cstr(s.pointee.title) ?? "?",
                        artist: cstr(s.pointee.artist) ?? "",
                        musicId: cstr(s.pointee.musicId) ?? ""))
                    scur = s.pointee.head.next.map {
                        UnsafeMutableRawPointer($0)
                            .assumingMemoryBound(to: PianoSong.self)
                    }
                }
                PianoDestroySearchResult(&d.pointee.searchResult)
            })
        return result
    }

    /// Create a station from a musicToken (the `musicId` of a search result).
    ///
    /// Search results carry a **musicToken** (e.g. `"R35828"`), not a
    /// trackToken. The core emits the `"musicToken"` JSON field only when the
    /// data `type` is `PIANO_MUSICTYPE_INVALID` (request.c CREATE_STATION).
    /// Using the SONG/ARTIST types would emit `"trackToken"`, which Pandora
    /// rejects with `{"stat":"fail","message":"An unexpected error occurred"}`.
    /// This matches the original `BarUiActCreateStation` exactly.
    ///
    /// The new station is appended to the handle's station list (response.c
    /// CREATE_STATION), so it will be `stations().last`.
    func createStation(musicToken: String) async throws {
        let t = cCopy(musicToken)
        defer { free(t) }
        try await runData(PIANO_REQUEST_CREATE_STATION) {
            (d: UnsafeMutablePointer<PianoRequestDataCreateStation_t>) in
            d.pointee.token = t
            PianoIosCreateStationFromMusicToken(d)
        }
    }

    /// Add a seed (musicId) to a station.
    func addSeed(to station: Station, musicId: String,
                 quick: Bool = false) async throws {
        let m = cCopy(musicId)
        defer { free(m) }
        try await runData(PIANO_REQUEST_ADD_SEED,
                          timeout: quick ? 12 : 30,
                          attempts: quick ? 1 : 3) {
            (d: UnsafeMutablePointer<PianoRequestDataAddSeed_t>) in
            d.pointee.station = station.raw
            d.pointee.musicId = m
        }
    }

    /// Toggle the QuickMix inclusion for all non-QuickMix stations: include
    /// all if none were included, include none if any were. The C helper
    /// (PianoIosToggleQuickMix) operates on the core's authoritative station
    /// list, so this is safe even if the Swift-side station snapshot is stale
    /// — it never writes through Swift-held raw pointers. Call this before
    /// `setQuickMix()` to apply the selection.
    /// Returns true if the non-QuickMix stations are now all included.
    @discardableResult
    func toggleQuickMixSelection() -> Bool {
        PianoIosToggleQuickMix(handle) != 0
    }

    /// Register which stations are included in the current QuickMix station's
    /// playlist. No per-station data: the core reads each station's
    /// `useQuickMix` flag (request.c SET_QUICKMIX builds quickMixStationIds).
    /// The caller sets those flags first. Only meaningful when the current
    /// station is itself a QuickMix station (`isQuickMix`).
    func setQuickMix() async throws {
        try await call(PIANO_REQUEST_SET_QUICKMIX, data: nil)
    }

    /// Rename the selected station.
    func renameStation(_ station: Station, newName: String,
                       quick: Bool = false) async throws {
        let n = cCopy(newName)
        defer { free(n) }
        try await runData(PIANO_REQUEST_RENAME_STATION,
                          timeout: quick ? 12 : 30,
                          attempts: quick ? 1 : 3) {
            (d: UnsafeMutablePointer<PianoRequestDataRenameStation_t>) in
            d.pointee.station = station.raw
            d.pointee.newName = n
        }
    }

    /// Delete a station (server + local list). After this call the
    /// `Station`'s underlying C struct is freed — do not use it again.
    func deleteStation(_ station: Station, quick: Bool = false) async throws {
        try await call(PIANO_REQUEST_DELETE_STATION,
                       data: UnsafeMutableRawPointer(station.raw),
                       timeout: quick ? 12 : 30,
                       attempts: quick ? 1 : 3)
    }

    /// Ask why the current song was played. Returns a human-readable
    /// explanation (may be empty if the server has none).
    func explain(_ song: Song) async throws -> String {
        var out = ""
        let cs = makeCSong(song)
        defer { freeCSong(cs) }
        try await runData(
            PIANO_REQUEST_EXPLAIN,
            setup: { (d: UnsafeMutablePointer<PianoRequestDataExplain_t>) in
                d.pointee.song = cs
                d.pointee.retExplain = nil
            },
            finish: { (d: UnsafeMutablePointer<PianoRequestDataExplain_t>) in
                if let e = d.pointee.retExplain {
                    out = String(cString: e)
                    free(e) // core malloc'd it (response.c EXPLAIN)
                }
            })
        return out
    }
}
