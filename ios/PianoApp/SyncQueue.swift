//
// SyncQueue.swift — optimistic controls + a retrying command queue.
//
// Makes the UI responsive regardless of the network (the same idea as the
// next-song audio prefetch, issue #39, applied to server commands): a Love
// colors the heart instantly, a Ban/Tired silences the song and skips
// immediately, a rename/delete updates the station list right away. The
// actual Pandora call is queued here and sent by AppModel's background sync
// loop as soon as a connection allows — including after an app relaunch,
// since the queue persists to UserDefaults.
//
// Copyright (c) 2025 Spencer Graffunder
// MIT licensed.
//

import Foundation

// MARK: - Queued command

/// A server-side change the app has ALREADY reflected in the UI locally,
/// waiting to be sent to Pandora.
///
/// Carries only value-type tokens (trackToken / station ids / musicId /
/// names) — never a `Station` or `Song` — because those wrap C structs the
/// core can free at any time. At send time the queue re-looks the station
/// up by id (`PianoClient.station(id:)`).
struct QueuedCommand: Codable, Equatable {
    enum Kind: String, Codable {
        case love, ban, tired, addSeed, rename, deleteStation
    }
    var kind: Kind
    /// Song the rating applies to. The C core reads only `trackToken` and
    /// `stationId` from a song for rate/tired (see PianoClient.makeCSong).
    var trackToken: String? = nil
    var songStationId: String? = nil
    /// Song name, carried so a command queued for a cached song that predates
    /// token storage (trackToken nil) can be resolved by search at send time.
    var songTitle: String? = nil
    var songArtist: String? = nil
    /// Target station for addSeed / rename / deleteStation.
    var stationId: String? = nil
    var musicId: String? = nil
    var newName: String? = nil
}

// MARK: - Persistence

/// Persists the pending queue to `UserDefaults` (the tokens are
/// non-sensitive, like the last-played-station id, so no Keychain needed).
/// Survives app termination: loves queued offline are sent on the next
/// launch once the Keychain auto-login gives us a logged-in client.
/// The `UserDefaults` instance is injectable so unit tests can run against
/// a private suite (same pattern as `LastStationStore`).
struct PendingCommandsStore {
    /// The single key used for the stored queue.
    static let key = "pending-commands-v1"

    var defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored queue (empty if none or undecodable).
    func load() -> [QueuedCommand] {
        guard let data = defaults.data(forKey: Self.key),
              let cmds = try? JSONDecoder().decode(
                    [QueuedCommand].self, from: data)
        else { return [] }
        return cmds
    }

    /// Store `cmds` (an empty queue removes the key entirely).
    func save(_ cmds: [QueuedCommand]) {
        if cmds.isEmpty {
            defaults.removeObject(forKey: Self.key)
            return
        }
        if let data = try? JSONEncoder().encode(cmds) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

// MARK: - Client gate

/// Serializes every use of the shared `PianoClient` (one C core handle is
/// not safe to drive from two requests at once).
///
/// Two classes of user:
///  - **Interactive** actions (`acquire`) — Play/Next/Explain/…; they take
///    the lock FIFO, exactly one in flight.
///  - **Background sync** (`tryAcquireForBackground`) — the queued-command
///    drain. It only takes the lock when NO interactive action is waiting,
///    so a slow "send the queued love" request can never delay a Next tap
///    that arrives while it's in flight. On release, waiting interactive
///    jobs get the lock before background waiters are even woken.
///
/// Everything runs on the main actor, which is also where PianoClient
/// calls already happen today — this is a cooperative turn-taking gate,
/// not a cross-thread mutex.
@MainActor
final class ClientGate {
    private var locked = false
    private var interactiveWaiters: [CheckedContinuation<Void, Never>] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// For tests: whether the lock is currently held.
    var isLocked: Bool { locked }
    /// For tests: number of interactive jobs queued behind the lock.
    var interactiveWaitCount: Int { interactiveWaiters.count }

    /// Wait for exclusive use. The lock is handed directly from the
    /// releasing holder to the next interactive waiter (no gap for the
    /// background drain to slip into).
    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { interactiveWaiters.append($0) }
    }

    /// Take the lock only if it is free AND no interactive job is waiting.
    func tryAcquireForBackground() -> Bool {
        guard !locked, interactiveWaiters.isEmpty else { return false }
        locked = true
        return true
    }

    /// Give up the lock (interactive or background holder).
    func release() {
        if !interactiveWaiters.isEmpty {
            // Hand off; the lock stays taken.
            interactiveWaiters.removeFirst().resume()
        } else {
            locked = false
            let waiters = idleWaiters
            idleWaiters = []
            for w in waiters { w.resume() }
        }
    }

    /// Resumes when the gate looks acquirable for background work
    /// (unlocked with no interactive waiters). Callers must still check
    /// `tryAcquireForBackground()` — it can lose a race with an interactive
    /// job that arrived after the wake-up.
    func waitUntilIdle() async {
        if !locked, interactiveWaiters.isEmpty { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }
}
