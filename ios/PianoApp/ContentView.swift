//
// ContentView.swift — one-screen, button-first pianobar UI.
// No artwork, no fancy layout. Everything is a big button on one screen:
// transport, ratings, song info, station management, quick mix, volume,
// and search. When an action needs text input (add seed / rename), a text
// box appears (alert + keyboard).
//
// Copyright (c) 2025 Spencer Graffunder
// MIT licensed.
//

import SwiftUI
import Combine
import UIKit
import MediaPlayer

// MARK: - View model

@MainActor
final class AppModel: ObservableObject, MediaSessionModel {
    // auth
    @Published var username = ""
    @Published var password = ""
    @Published var loggedIn = false

    // data
    @Published var stations: [Station] = []
    @Published var selectedStationID: String?
    /// Full playlist from the last getPlaylist (song[0] is current, the
    /// rest are upcoming). The C structs are owned by the core and stay
    /// valid until the next getPlaylist call, so the whole array is
    /// replaced together — never keep a Song across a getPlaylist.
    @Published var playlist: [Song] = []
    @Published var searchText = ""
    @Published var searchResult: SearchResult?

    // Love toggle state (per-song, session-scoped). Pandora has no query for
    // "is this song loved", so we track which songs the user has loved here.
    @Published var lovedSongIDs: Set<String> = []
    // "Add Music" search sheet (search box is no longer always visible).
    @Published var showAddSearch = false

    // ui
    @Published var status = "Enter your Pandora account to begin."
    @Published var isWorking = false
    @Published var showUpcoming = false

    // text-input prompts
    @Published var prompt: Prompt?

    enum Prompt: Identifiable {
        case rename
        var id: Self { self }
    }
    @Published var promptText = ""
    @Published var confirmDelete = false

    // playback (forward Player's changes to our own objectWillChange)
    @Published private(set) var player = Player()
    private var playerCancellable: AnyCancellable?

    /// Now Playing / lock screen / remote-control layer.
    private var media: MediaSession!

    /// A saved .m4a ready to share (Music / Files / …).
    @Published var shareItem: ShareItem?
    /// Device-picker sheet (stock iOS output picker).
    @Published var showDevicePicker = false

    private var client: PianoClient?
    private var working = false

    init() {
        playerCancellable = player.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        media = MediaSession(model: self)
        // Restore saved credentials and log in automatically, so the user
        // doesn't have to re-enter them on every launch. (If the login
        // fails — bad password, no network — the error shows in the status
        // line and the login screen stays up.)
        if let saved = Keychain.load() {
            username = saved.username
            password = saved.password
            login()
        }
    }

    // MARK: Derived state

    var selectedStation: Station? {
        guard let id = selectedStationID else { return nil }
        return stations.first { $0.stableId == id }
    }

    // MARK: MediaSessionModel (lock screen / Control Center / Bluetooth)

    var npTitle: String? { currentSong?.title }
    var npArtist: String? { currentSong?.artist }
    var npAlbum: String? { currentSong?.album }
    /// Prefer the player's measured duration; fall back to the core's
    /// song length (seconds).
    var npDuration: Double {
        let d = player.duration
        if d > 0 { return d }
        return Double(currentSong?.length ?? 0)
    }
    var npElapsed: Double { player.elapsed }

    var isPlayingNow: Bool { player.isPlaying }

    func modelPlay() {
        if let url = currentSong?.audioUrl, let u = URL(string: url) {
            player.play(url: u)
            updateNowPlaying()
        }
    }

    func modelPause() {
        player.pause()
        updateNowPlaying()
    }

    func modelNext() { nextSong() }
    func modelPrevious() { nextSong() } // Pandora: no backward skip

    func resumable() -> Bool {
        player.isPlaying || player.elapsed > 0
    }

    /// Publish the current song + transport state to Now Playing.
    private func updateNowPlaying() {
        media.updateNowPlaying(
            title: npTitle, artist: npArtist, album: npAlbum,
            duration: npDuration, elapsed: npElapsed,
            playing: player.isPlaying)
    }

    var currentSong: Song? { playlist.first }

    var upcoming: [Song] { Array(playlist.dropFirst()) }

    /// Whether the currently-playing song is loved. True if the user loved
    /// it this session, OR if the server says so: the core parses the
    /// playlist's `songRating: 1` into `song->rating == PIANO_RATE_LOVE`
    /// (response.c GET_PLAYLIST), which covers songs loved days ago or from
    /// a different client.
    var isCurrentLoved: Bool {
        guard let s = currentSong else { return false }
        return s.rating == PIANO_RATE_LOVE
            || lovedSongIDs.contains(s.id)
    }

    // MARK: - Actions (each runs one C-core exchange; state stays on main)

    private func run(_ label: String,
                     _ work: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true
        isWorking = true
        status = label + "…"
        Task {
            do {
                try await work()
                status = label + " done."
            } catch {
                status = "Error: \(error.localizedDescription)"
            }
            isWorking = false
            working = false
        }
    }

    // MARK: Auth

    func login() {
        guard !username.isEmpty, !password.isEmpty else { return }
        run("Logging in") { [weak self] in
            guard let self else { return }
            if self.client == nil {
                self.client = try PianoClient(
                    username: self.username, password: self.password)
            }
            guard let client = self.client else { return }
            try await client.login()
            self.loggedIn = true
            // Remember the credentials for next time. (If the keychain is
            // unavailable the login still works; we just won't auto-login
            // next time.)
            var saveStatus = Keychain.save(username: self.username, password: self.password)
            try await client.getStations()
            self.stations = client.stations()
            if self.selectedStationID == nil, let first = self.stations.first {
                self.selectedStationID = first.stableId
            }
            if saveStatus == errSecSuccess {
                self.status = "Logged in. \(self.stations.count) station(s)."
            } else {
                self.status = "Logged in (couldn't remember credentials: OSStatus \(saveStatus)). \(self.stations.count) station(s)."
            }
        }
    }

    func refreshStations() {
        guard let client = client else { return }
        run("Loading stations") { [weak self] in
            guard let self else { return }
            try await client.getStations()
            self.stations = client.stations()
            // Re-point selection if the current one vanished.
            if let id = self.selectedStationID,
               !self.stations.contains(where: { $0.stableId == id }) {
                self.selectedStationID = self.stations.first?.stableId
            } else if self.selectedStationID == nil,
                let first = self.stations.first {
                self.selectedStationID = first.stableId
            }
        }
    }

    func logout() {
        // The C core has no explicit logout; drop our session.
        client = nil
        loggedIn = false
        stations = []
        playlist = []
        searchResult = nil
        selectedStationID = nil
        player.stop()
        media.clearNowPlaying()
        // Forget the saved credentials so the next launch shows the login
        // screen. (Re-login stores the new credentials again.) Keep the
        // username for convenience; clear the password.
        Keychain.delete()
        password = ""
        status = "Logged out."
    }

    // MARK: Transport

    private func playIfAvailable() {
        if let url = currentSong?.audioUrl, let u = URL(string: url) {
            player.play(url: u)
            updateNowPlaying()
        } else if currentSong != nil {
            status = "This song has no audio URL."
        }
    }

    func nextSong() {
        guard let client = client, let station = selectedStation else {
            status = "Pick a station first."
            return
        }
        run("Next song") { [weak self] in
            guard let self else { return }
            let songs = try await client.getPlaylist(station: station)
            self.playlist = songs
            self.showUpcoming = false
            self.playIfAvailable()
        }
    }

    func togglePlayback() {
        if player.isPlaying {
            player.pause()
            updateNowPlaying()
        } else if let url = currentSong?.audioUrl, let u = URL(string: url) {
            player.play(url: u)
            updateNowPlaying()
        } else {
            // No playable song yet (empty queue, or the current song has no
            // audio URL) — fetch the next song from the station and start it.
            nextSong()
        }
    }

    func stopPlayback() {
        player.stop()
        updateNowPlaying()
        status = "Stopped."
    }

    // MARK: Rating

    private func advanceAfterRating() async throws {
        guard let client = client, let station = selectedStation else { return }
        let songs = try await client.getPlaylist(station: station)
        playlist = songs
        showUpcoming = false
        playIfAvailable()
    }

    func rate(_ rating: PianoSongRating_t, label: String) {
        guard let client = client, let song = currentSong else {
            status = "Play a song first."
            return
        }
        run(label) { [weak self] in
            guard let self else { return }
            try await client.rateSong(song, rating: rating)
            try await self.advanceAfterRating()
        }
    }

    /// Love is a toggle on the current song (it does NOT skip):
    ///  - first press: registers the love with Pandora + colors the heart
    ///  - second press on the same song: un-colors it (clears local state).
    /// "Loved" includes songs the server already marked loved (see
    /// isCurrentLoved), so the second press must also clear the rating the
    /// core read from the server — Pandora has no "un-love" API, so that
    /// only clears local state.
    func toggleLove() {
        guard let song = currentSong else {
            status = "Play a song first."
            return
        }
        if isCurrentLoved {
            lovedSongIDs.remove(song.id)
            // Clear the server-loved flag on the stored copy so the heart
            // un-highlights (Pandora has no un-love API; this is local state).
            if song.rating == PIANO_RATE_LOVE,
               let i = playlist.firstIndex(where: { $0.id == song.id }) {
                playlist[i].rating = PIANO_RATE_NONE
            }
            status = "Un-loved."
        } else {
            lovedSongIDs.insert(song.id)
            guard let client = client else { status = "Loved."; return }
            let c = client
            run("Loving") {
                try await c.rateSong(song, rating: PIANO_RATE_LOVE)
            }
        }
    }

    func markTired() {
        guard let client = client, let song = currentSong else {
            status = "Play a song first."
            return
        }
        run("Tired") { [weak self] in
            guard let self else { return }
            try await client.markTired(song)
            try await self.advanceAfterRating()
        }
    }

    // MARK: Song info

    func explainSong() {
        guard let client = client, let song = currentSong else {
            status = "Play a song first."
            return
        }
        run("Explaining") { [weak self] in
            guard let self else { return }
            let why = try await client.explain(song)
            self.status = why.isEmpty
                ? "No explanation available for this song."
                : why
        }
    }

    func bookmarkSong() {
        guard let client = client, let song = currentSong else {
            status = "Play a song first."
            return
        }
        run("Bookmarking") { [weak self] in
            guard let self else { return }
            try await client.bookmark(song)
            self.status = "Bookmarked."
        }
    }

    func toggleUpcoming() {
        showUpcoming.toggle()
    }

    // MARK: Station management

    func startRename() {
        guard let station = selectedStation else {
            status = "Pick a station first."
            return
        }
        promptText = station.name ?? ""
        prompt = .rename
    }

    func confirmRename() {
        guard let client = client, let station = selectedStation else { return }
        let name = promptText.trimmingCharacters(in: .whitespaces)
        prompt = nil
        guard !name.isEmpty else { return }
        run("Renaming") { [weak self] in
            guard let self else { return }
            try await client.renameStation(station, newName: name)
            // The core updated the name in place; refresh the list copy.
            self.stations = client.stations()
            self.status = "Station renamed."
        }
    }

    func deleteStation() {
        guard let client = client, let station = selectedStation else { return }
        run("Deleting") { [weak self] in
            guard let self else { return }
            try await client.deleteStation(station)
            // The core freed the station and removed it from the list.
            self.stations = client.stations()
            self.selectedStationID = self.stations.first?.stableId
            self.playlist = []
            self.player.stop()
            self.status = "Station deleted."
        }
    }

    // MARK: Quick mix

    func toggleQuickMix() {
        guard let client = client, let station = selectedStation else {
            status = "Pick a station first."
            return
        }
        guard station.isQuickMix else {
            status = "The current station is not a QuickMix station."
            return
        }
        // On/off: if any station is currently included, turn all off, else
        // include every non-quickmix station.
        let anyOn = stations.contains { $0.useQuickMix }
        let include: Int8 = anyOn ? 0 : 1
        run("Quick Mix") { [weak self] in
            guard let self else { return }
            for s in self.stations where !s.isQuickMix {
                s.raw.pointee.useQuickMix = include
            }
            try await client.setQuickMix()
            self.status = anyOn ? "QuickMix stations cleared."
                : "QuickMix includes all stations."
            // Pick up the new mix.
            if let st = self.selectedStation {
                let songs = try await client.getPlaylist(station: st)
                self.playlist = songs
                self.showUpcoming = false
                self.playIfAvailable()
            }
        }
    }

    // MARK: Volume

    func volumeDown() { player.nudgeVolume(-0.1) }
    func volumeUp()   { player.nudgeVolume(+0.1) }
    func volumeReset() {
        player.resetVolume()
        status = "Volume reset."
    }

    // MARK: Save song (download + transcode → share to Music/Files)

    /// Download the current song and transcode to .m4a, then present the
    /// system share sheet (Music and Files are both share targets).
    func saveSong() {
        guard let song = currentSong,
              let urlStr = song.audioUrl,
              let url = URL(string: urlStr) else {
            status = "No song to save."
            return
        }
        guard !working else { return }
        working = true
        isWorking = true
        status = "Saving song…"
        Task { [weak self] in
            do {
                let file = try await SongSaver.save(url: url,
                                                     title: song.title ?? "")
                self?.status = "Saved — choose where to put it."
                self?.shareItem = ShareItem(url: file)
            } catch {
                self?.status = "Save failed: \(error.localizedDescription)"
            }
            self?.isWorking = false
            self?.working = false
        }
    }

    // MARK: Search

    func doSearch() {
        guard let client = client, !searchText.isEmpty else { return }
        run("Searching") { [weak self] in
            guard let self else { return }
            self.searchResult = try await client.search(self.searchText)
        }
    }

    private func makeStation(musicToken: String, name: String) {
        guard let client = client, !musicToken.isEmpty else { return }
        run("Making station for \(name)") { [weak self] in
            guard let self else { return }
            try await client.createStation(musicToken: musicToken)
            try await client.getStations()
            self.stations = client.stations()
            if let newStation = self.stations.last {
                self.selectedStationID = newStation.stableId
            }
            self.searchResult = nil
            self.status = "Station \"\(name)\" created."
        }
    }

    func makeStationFromArtist(_ artist: SearchArtist) {
        makeStation(musicToken: artist.musicId, name: artist.name)
    }

    func makeStationFromSong(_ song: SearchSong) {
        makeStation(musicToken: song.musicId, name: song.title)
    }

    /// Add a search result to the current station as a seed (driven by the
    /// "Add Music" sheet). Results carry a musicId usable as a seed directly.
    func addSeedFromMusicId(_ musicId: String) {
        guard let client = client, let station = selectedStation,
              !musicId.isEmpty else { return }
        let c = client
        run("Adding music") {
            try await c.addSeed(to: station, musicId: musicId)
        }
    }
}

// MARK: - Control button descriptor

private struct Control: Identifiable {
    enum Role { case normal, prominent, destructive, loved }
    let id: String
    let title: String
    let systemImage: String
    let role: Role
    let enabled: Bool
    let action: () -> Void
}

// MARK: - View

struct ContentView: View {
    @StateObject private var model = AppModel()
    @FocusState private var focus: Field?

    private enum Field { case username, password }

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if !model.loggedIn {
                    loginView
                } else {
                    mainView
                }
            }
            .padding(.horizontal)
            .navigationTitle("pianobar")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
        // Rename prompt — opens keyboard + text box.
        .alert(
            "Rename station",
            isPresented: promptBinding
        ) {
            TextField(
                "new station name",
                text: $model.promptText
            )
            .autocorrectionDisabled()
            .autocapitalization(.none)
            Button("Cancel", role: .cancel) { model.prompt = nil }
            Button("OK") { model.confirmRename() }
                .disabled(model.promptText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .confirmationDialog(
            "Delete this station?",
            isPresented: $model.confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete station") {
                model.deleteStation()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var promptBinding: Binding<Bool> {
        Binding(
            get: { model.prompt != nil },
            set: { if !$0 { model.prompt = nil } }
        )
    }

    // MARK: Login

    private var loginView: some View {
        VStack(spacing: 14) {
            Spacer()
            TextField("username", text: $model.username)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .autocapitalization(.none)
                .focused($focus, equals: .username)
            SecureField("password", text: $model.password)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .password)
                .submitLabel(.go)
                .onSubmit { model.login() }
            Button("Log in", action: model.login)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isWorking || model.username.isEmpty)
            Text(model.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
    }

    // MARK: Main (everything on one screen)

    private var mainView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                stationBar
                currentSongCard
                controlGrid
                if model.showUpcoming {
                    upcomingList
                }
                statusText
            }
            .padding(.vertical, 8)
            .padding(.bottom, 32)
        }
        .sheet(isPresented: $model.showAddSearch) {
            AddMusicSheet(model: model)
        }
        .sheet(isPresented: $model.showDevicePicker) {
            DevicePickerSheet()
        }
        .sheet(item: $model.shareItem) { ShareSheet(url: $0.url) }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { model.refreshStations() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                Button { model.logout() } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .onAppear {
            if !model.loggedIn { focus = .username }
        }
    }

    private var stationBar: some View {
        HStack {
            Picker("Station", selection: $model.selectedStationID) {
                Text("—").tag(String?.none)
                ForEach(model.stations) { s in
                    Text(s.name ?? s.stableId).tag(Optional(s.stableId))
                }
            }
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private var currentSongCard: some View {
        if let song = model.currentSong {
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title ?? "(untitled)").font(.headline)
                Text(song.artist ?? "").font(.subheadline)
                    .foregroundStyle(.secondary)
                if let album = song.album {
                    Text(album).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 10))
        } else {
            Text("No song yet — tap Next.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var controlGrid: some View {
        let hasSong = model.currentSong != nil
        let hasStation = model.selectedStation != nil
        let hasUpcoming = model.upcoming.count > 0
        let controls: [Control] = [
            .init(id: "playpause", title: model.player.isPlaying ? "Pause" : "Play",
                  systemImage: model.player.isPlaying ? "pause.fill" : "play.fill",
                  role: .prominent, enabled: !model.player.isPlaying || hasSong,
                  action: model.togglePlayback),
            .init(id: "next", title: "Next", systemImage: "forward.fill",
                  role: .normal, enabled: hasStation, action: model.nextSong),
            .init(id: "stop", title: "Stop", systemImage: "stop.fill",
                  role: .normal, enabled: model.player.isPlaying,
                  action: model.stopPlayback),
            .init(id: "upcoming", title: "Upcoming", systemImage: "list.bullet",
                  role: .normal, enabled: hasUpcoming,
                  action: model.toggleUpcoming),
            .init(id: "love", title: model.isCurrentLoved ? "Loved" : "Love",
                  systemImage: "heart.fill",
                  role: model.isCurrentLoved ? .loved : .normal,
                  enabled: hasSong,
                  action: model.toggleLove),
            .init(id: "ban", title: "Ban", systemImage: "nosign",
                  role: .normal, enabled: hasSong,
                  action: { model.rate(PIANO_RATE_BAN, label: "Banning") }),
            .init(id: "tired", title: "Tired", systemImage: "zzz",
                  role: .normal, enabled: hasSong,
                  action: model.markTired),
            .init(id: "explain", title: "Explain", systemImage: "questionmark.circle",
                  role: .normal, enabled: hasSong, action: model.explainSong),
            .init(id: "bookmark", title: "Bookmark", systemImage: "bookmark.fill",
                  role: .normal, enabled: hasSong, action: model.bookmarkSong),
            .init(id: "addseed", title: "Add Music", systemImage: "plus.circle",
                  role: .normal, enabled: hasStation,
                  action: { model.showAddSearch = true }),
            .init(id: "rename", title: "Rename", systemImage: "pencil",
                  role: .normal, enabled: hasStation, action: model.startRename),
            .init(id: "delete", title: "Delete", systemImage: "trash",
                  role: .normal, enabled: hasStation,
                  action: { model.confirmDelete = true }),
            .init(id: "quickmix", title: "Quick Mix", systemImage: "shuffle",
                  role: .normal, enabled: hasStation, action: model.toggleQuickMix),
            .init(id: "device", title: "Device", systemImage: "hifispeaker",
                  role: .normal, enabled: true,
                  action: { model.showDevicePicker = true }),
            .init(id: "save", title: "Save", systemImage: "square.and.arrow.down",
                  role: .normal,
                  enabled: hasSong && model.currentSong?.audioUrl != nil,
                  action: model.saveSong),
        ]

        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(controls) { c in
                Button(action: c.action) {
                    VStack(spacing: 6) {
                        Image(systemName: c.systemImage)
                            .font(.system(size: 20, weight: .semibold))
                        Text(c.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 62)
                }
                .buttonStyle(GridButtonStyle(role: c.role))
                .disabled(!c.enabled || model.isWorking)
            }
        }
    }

    private var upcomingList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Up next")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(model.upcoming.prefix(4).enumerated()),
                    id: \.element.id) { i, song in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(i + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 14, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.title ?? "(untitled)")
                            .font(.footnote)
                        Text(song.artist ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var statusText: some View {
        let err = model.player.lastError
        Text(err ?? model.status)
            .font(.footnote)
            .foregroundStyle(err != nil ? Color.red : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

// MARK: - Add Music sheet

/// Search sheet presented by the "Add Music" button. Search for an artist or
/// song and tap a result to add it to the current station as a seed.
struct AddMusicSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("artist, song, or music token",
                              text: $model.searchText)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                        .focused($focused)
                        .submitLabel(.search)
                        .onSubmit { model.doSearch() }
                    Button("Search") { model.doSearch() }
                        .buttonStyle(.bordered)
                        .disabled(model.searchText.isEmpty || model.isWorking)
                }

                if let result = model.searchResult {
                    if !result.artists.isEmpty {
                        Text("Artists — tap to add to station")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(result.artists) { a in
                            Button {
                                model.addSeedFromMusicId(a.musicId)
                                dismiss()
                            } label: {
                                Text(a.name)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    if !result.songs.isEmpty {
                        Text("Songs — tap to add to station")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(result.songs) { s in
                            Button {
                                model.addSeedFromMusicId(s.musicId)
                                dismiss()
                            } label: {
                                Text("\(s.title) — \(s.artist)")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    if result.isEmpty {
                        Text("No results.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Search for an artist or song to add to the current station.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Add Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        model.searchResult = nil
                        model.searchText = ""
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { focused = true }
    }
}

// MARK: - Button styling

private struct GridButtonStyle: ButtonStyle {
    let role: Control.Role

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(border, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.6 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch role {
        case .prominent: return .white
        case .destructive: return .red
        case .loved: return .red
        case .normal: return .primary
        }
    }

    private var background: Color {
        switch role {
        case .prominent: return .accentColor
        case .destructive: return Color.red.opacity(0.1)
        case .loved: return Color.red.opacity(0.15)
        case .normal: return Color(.secondarySystemBackground)
        }
    }

    private var border: Color {
        switch role {
        case .prominent: return .clear
        case .destructive: return .red.opacity(0.35)
        case .loved: return .red.opacity(0.5)
        case .normal: return Color(.separator).opacity(0.4)
        }
    }
}

#Preview {
    ContentView()
}

// MARK: - Device picker (stock iOS output picker)

/// A saved song file, Identifiable for `.sheet(item:)`.
struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// A button showing the stock iOS route button (speaker icon). Tapping
/// it opens the system output picker (speaker / headphones / Bluetooth /
/// AirPlay) — the same picker the volume HUD shows in other apps.
struct DevicePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView()
        v.showsRouteButton = true   // includes AirPlay on modern iOS
        v.showsVolumeSlider = false
        v.frame = CGRect(x: 0, y: 0, width: 48, height: 48)
        return v
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// Sheet with the stock output picker (the system AirPlay/output button
/// from `MPVolumeView` — tapping it opens the stock picker listing
/// speaker, headphones, Bluetooth, and AirPlay targets).
struct DevicePickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Play through…")
                .font(.headline)
            DevicePickerButton()
                .frame(width: 64, height: 64)
            Text("Tap the speaker button to open the system picker\n(speaker, headphones, Bluetooth, AirPlay).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding(24)
    }
}

// MARK: - Share sheet (saved song → Music / Files / …)

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url],
                                 applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController,
                                context: Context) {}
}
