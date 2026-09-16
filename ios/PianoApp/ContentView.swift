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
    /// Help sheet (explains every button).
    @Published var showHelp = false

    private var client: PianoClient?
    private var working = false
    /// Remembers the last station the user played so the app can restore
    /// and auto-play it on the next launch (issue #4). Injectable so tests
    /// can point it at a private `UserDefaults` suite.
    var lastStation: LastStationStore = LastStationStore()

    init() {
        playerCancellable = player.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // When a song finishes playing naturally, fetch and start the next
        // one from the current station (issue #16). The callback fires on
        // the main thread; the model is main-actor isolated.
        player.onSongFinished = { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.nextSong()
            }
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

    /// Whether the currently-playing song has been loved (toggle state).
    var isCurrentLoved: Bool {
        guard let s = currentSong else { return false }
        return lovedSongIDs.contains(s.id)
    }

    // MARK: - Actions (each runs one C-core exchange; state stays on main)

    private func run(_ label: String,
                     _ work: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true
        isWorking = true
        status = label + "…"
        let started = status
        Task {
            do {
                try await work()
                // Only apply the default success message when the action
                // did not set a more specific one itself (e.g. the Explain
                // button's "We're playing this track because it features …").
                if status == started { status = label + " done." }
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
            // Restore the most recently played station (issue #4); fall
            // back to the first station if there's none saved or it's gone.
            if let last = self.lastStation.load(),
               let match = self.stations.first(where: { $0.stableId == last }) {
                self.selectedStationID = match.stableId
            } else if self.selectedStationID == nil, let first = self.stations.first {
                self.selectedStationID = first.stableId
            }
            // Auto-play a song from the selected station on launch (issue
            // #4). Covers both "restore the last station and play from it"
            // and "no station was played before — start from the first".
            // A failure here must not hide the fact that the login itself
            // succeeded.
            if saveStatus == errSecSuccess {
                self.status = "Logged in. \(self.stations.count) station(s)."
            } else {
                self.status = "Logged in (couldn't remember credentials: OSStatus \(saveStatus)). \(self.stations.count) station(s)."
            }
            do {
                try await self.autoPlayFirstSongIfNeeded()
            } catch {
                self.status = "Logged in, but couldn't start music: \(error.localizedDescription)"
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
        // Forget the last-played station too: it belongs to this account,
        // and the next person to log in shouldn't be auto-started into it
        // (issue #4).
        lastStation.save(nil)
        status = "Logged out."
    }

    // MARK: Transport

    private func playIfAvailable() {
        if let url = currentSong?.audioUrl, let u = URL(string: url) {
            // A song is starting from this station — remember it as the
            // most recently played so the app can restore it on launch
            // (issue #4).
            if let id = selectedStation?.stableId {
                lastStation.save(id)
            }
            player.play(url: u)
            updateNowPlaying()
        } else if currentSong != nil {
            status = "This song has no audio URL."
        }
    }

    /// Start (or restart) a song on the currently selected station. Used
    /// for issue #4's auto-play: on launch, after a station is created, or
    /// when the user picks a station while paused. Fetches the playlist
    /// (so there is always a song to play) and starts it.
    private func autoPlayFirstSongIfNeeded() async throws {
        guard let station = selectedStation else { return }
        let songs = try await client?.getPlaylist(station: station) ?? []
        playlist = songs
        showUpcoming = false
        playIfAvailable()
    }

    /// Called when the user picks a station in the station bar (issue #4).
    /// Always reflects the choice; and when nothing is playing (paused or
    /// no song yet), starts a song from the newly selected station. While a
    /// song is playing we leave it running — switching stations mid-song is
    /// a deliberate "pause + switch" the user can act on.
    func stationDidSelect(_ id: String?) {
        selectedStationID = id
        guard let id,
              stations.contains(where: { $0.stableId == id }),
              player.isPlaying == false
        else { return }
        Task { @MainActor in
            do {
                try await self.autoPlayFirstSongIfNeeded()
            } catch {
                self.status = "Couldn't start music: \(error.localizedDescription)"
            }
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
            self.markStationCurrent(station)
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

    // MARK: Rating

    private func advanceAfterRating() async throws {
        guard let client = client, let station = selectedStation else { return }
        let songs = try await client.getPlaylist(station: station)
        playlist = songs
        markStationCurrent(station)
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
    /// Pandora has no "un-love" API, so the second press only clears state.
    func toggleLove() {
        guard let song = currentSong else {
            status = "Play a song first."
            return
        }
        if lovedSongIDs.contains(song.id) {
            lovedSongIDs.remove(song.id)
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

    func toggleUpcoming() {
        showUpcoming.toggle()
    }

    // MARK: Station management

    /// The station a playlist was last fetched for. Lets us distinguish a
    /// real user switch from the initial selection after login, so the
    /// station picker's onChange doesn't trigger a redundant fetch.
    private var lastStationID: String?

    /// Record that the playlist now belongs to this station.
    private func markStationCurrent(_ station: Station) {
        lastStationID = station.stableId
    }

    /// Fired when the user switches stations in the picker: drop the
    /// previous station's queue and start a song from the new station.
    /// Without this, the current song + playback keep pointing at the
    /// old station's queue until the user taps Next. Requires that a
    /// station was already active (lastStationID set), so the initial
    /// auto-selection at login does NOT trigger a fetch — the app still
    /// waits for an explicit Play/Next there.
    func stationDidChange() {
        guard let station = selectedStation,
              let last = lastStationID,
              station.stableId != last else { return }
        playlist = []
        showUpcoming = false
        player.stop()
        media.clearNowPlaying()
        nextSong()
    }

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
        // Toggle in C (include all if none are included, clear all if any
        // are), then apply the selection on the server.
        run("Select Stations") { [weak self] in
            guard let self else { return }
            // Set the selection in C (operates on the core's authoritative
            // station list — no Swift-held raw pointers), then tell the
            // server. This is what makes it work without crashing.
            let included = client.toggleQuickMixSelection()
            try await client.setQuickMix()
            // Pick up the new mix.
            if let st = self.selectedStation {
                let songs = try await client.getPlaylist(station: st)
                self.playlist = songs
                self.markStationCurrent(st)
                self.showUpcoming = false
                self.playIfAvailable()
            }
            self.status = included ? "All stations included in QuickMix."
                : "QuickMix cleared."
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
            // Start music from the new station — the user just created and
            // selected it, and nothing is playing yet (issue #4). The play
            // also records it as the most recently played station.
            try await self.autoPlayFirstSongIfNeeded()
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
    /// When true, the tile renders the stock iOS output picker inline
    /// (speaker / headphones / Bluetooth / AirPlay) instead of an SF Symbol,
    /// and the picker button itself owns the tap.
    var isDevicePicker: Bool = false
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
        .sheet(isPresented: $model.showHelp) {
            HelpSheet()
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
            Picker("Station", selection: Binding(
            get: { model.selectedStationID },
            set: { model.stationDidSelect($0) }
        )) {
                Text("—").tag(String?.none)
                ForEach(model.stations) { s in
                    Text(s.name ?? s.stableId).tag(Optional(s.stableId))
                }
            }
            .pickerStyle(.menu)
            // Switching stations must start a song from the NEW station —
            // otherwise the current-song card and playback keep pointing at
            // the previous station's queue until the user taps Next.
            .onChange(of: model.selectedStationID) { _ in
                model.stationDidChange()
            }
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
            .init(id: "addseed", title: "Add Music", systemImage: "plus.circle",
                  role: .normal, enabled: hasStation,
                  action: { model.showAddSearch = true }),
            .init(id: "rename", title: "Rename", systemImage: "pencil",
                  role: .normal, enabled: hasStation, action: model.startRename),
            .init(id: "delete", title: "Delete", systemImage: "trash",
                  role: .normal, enabled: hasStation,
                  action: { model.confirmDelete = true }),
            .init(id: "quickmix", title: "Select Stations", systemImage: "shuffle",
                  role: .normal,
                  enabled: hasStation && model.selectedStation?.isQuickMix == true,
                  action: model.toggleQuickMix),
            .init(id: "device", title: "Device", systemImage: "hifispeaker",
                  role: .normal, enabled: true, isDevicePicker: true,
                  action: {}),
            .init(id: "save", title: "Save", systemImage: "square.and.arrow.down",
                  role: .normal,
                  enabled: hasSong && model.currentSong?.audioUrl != nil,
                  action: model.saveSong),
            .init(id: "help", title: "Help", systemImage: "questionmark.circle",
                  role: .normal, enabled: true,
                  action: { model.showHelp = true }),
        ]

        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(controls) { c in
                if c.isDevicePicker {
                    // Native iOS output picker, inline on the main screen.
                    // No SwiftUI Button wrapper — that would swallow the tap.
                    // A VStack is a plain layout container, so the embedded
                    // route button (speaker icon) keeps its own hit-testing
                    // and opens the system sheet (speaker / headphones /
                    // Bluetooth / AirPlay) when tapped.
                    VStack(spacing: 6) {
                        DevicePickerButton()
                            .frame(width: 30, height: 30)
                        Text(c.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 62)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color(.separator).opacity(0.4),
                                          lineWidth: 1)
                    )
                    .disabled(model.isWorking)
                } else {
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

// MARK: - Help sheet (what each button does)

/// One row in the help sheet: icon, name, one-sentence explanation.
private struct HelpEntry: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let detail: String
}

/// Large sheet opened from the Help button. Lists every other button in the
/// app (grid + toolbar), each with a one-sentence explanation.
struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let entries: [HelpEntry] = [
        HelpEntry(id: "playpause", title: "Play / Pause", systemImage: "play.fill",
                  detail: "Starts or pauses the current song; if nothing is queued it fetches the next song from your station first."),
        HelpEntry(id: "next", title: "Next", systemImage: "forward.fill",
                  detail: "Skips ahead and starts the next song from the selected station."),
        HelpEntry(id: "stop", title: "Stop", systemImage: "stop.fill",
                  detail: "Stops playback and clears the queue."),
        HelpEntry(id: "upcoming", title: "Upcoming", systemImage: "list.bullet",
                  detail: "Toggles the list of the next few songs in the queue."),
        HelpEntry(id: "love", title: "Love", systemImage: "heart.fill",
                  detail: "Tells Pandora you love this song so you'll hear more like it; tap again on the same song to clear the heart."),
        HelpEntry(id: "ban", title: "Ban", systemImage: "nosign",
                  detail: "Tells Pandora to stop playing this song and then moves on to the next one."),
        HelpEntry(id: "tired", title: "Tired", systemImage: "zzz",
                  detail: "Tells Pandora you've heard this one too many times and then moves on to the next song."),
        HelpEntry(id: "explain", title: "Explain", systemImage: "questionmark.circle",
                  detail: "Shows Pandora's reason for playing this song (which seed it came from)."),
        HelpEntry(id: "addseed", title: "Add Music", systemImage: "plus.circle",
                  detail: "Opens a search where you can add an artist or song to the current station as a seed."),
        HelpEntry(id: "rename", title: "Rename", systemImage: "pencil",
                  detail: "Renames the currently selected station."),
        HelpEntry(id: "delete", title: "Delete", systemImage: "trash",
                  detail: "Deletes the currently selected station from your account."),
        HelpEntry(id: "quickmix", title: "Quick Mix", systemImage: "shuffle",
                  detail: "On a QuickMix station, switches which of your stations it blends and plays the new mix."),
        HelpEntry(id: "device", title: "Device", systemImage: "hifispeaker",
                  detail: "Opens the system picker to choose where audio plays (speaker, headphones, Bluetooth, AirPlay)."),
        HelpEntry(id: "save", title: "Save", systemImage: "square.and.arrow.down",
                  detail: "Downloads the current song as an .m4a and lets you save it to Music or Files."),
        HelpEntry(id: "refresh", title: "Refresh", systemImage: "arrow.clockwise",
                  detail: "Re-loads your station list from your Pandora account (top-right toolbar)."),
        HelpEntry(id: "logout", title: "Log out", systemImage: "rectangle.portrait.and.arrow.right",
                  detail: "Ends the session and returns you to the login screen (top-right toolbar)."),
    ]

    var body: some View {
        NavigationStack {
            List(entries) { e in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: e.systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 26)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title)
                            .font(.subheadline.weight(.semibold))
                        Text(e.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .navigationTitle("What each button does")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Device picker (stock iOS output picker)

/// A saved song file, Identifiable for `.sheet(item:)`.
struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// A stock iOS route button (speaker icon). Tapping it opens the system
/// output picker (speaker / headphones / Bluetooth / AirPlay) — the same
/// picker the volume HUD shows in other apps. Rendered inline in the
/// Device tile on the main screen (no popup sheet).
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
