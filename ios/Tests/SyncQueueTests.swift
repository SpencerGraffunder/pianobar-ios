//
// SyncQueueTests.swift — tests for the offline command queue pieces.
//
// Covers: queue persistence round-trip, and the ClientGate priority rule
// (background sync never overtakes a waiting interactive action).
//
// Copyright (c) 2025 Spencer Graffunder
// MIT licensed.
//

import XCTest
@testable import PianoApp

final class SyncQueueTests: XCTestCase {

    // MARK: PendingCommandsStore

    func testCommandRoundTrip() throws {
        let suiteName = "SyncQueueTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PendingCommandsStore(defaults: defaults)

        XCTAssertTrue(store.load().isEmpty)

        let cmds: [QueuedCommand] = [
            .init(kind: .love, trackToken: "T1", songStationId: "S1"),
            .init(kind: .tired, trackToken: "T2", songStationId: "S1"),
            .init(kind: .addSeed, stationId: "S2", musicId: "M9"),
            .init(kind: .rename, stationId: "S2", newName: "My Station"),
            .init(kind: .deleteStation, stationId: "S3"),
        ]
        store.save(cmds)
        XCTAssertEqual(store.load(), cmds)

        // An empty queue clears the key entirely (nothing stale lingers).
        store.save([])
        XCTAssertNil(defaults.data(forKey: PendingCommandsStore.key))
        XCTAssertTrue(store.load().isEmpty)
    }

    func testGarbageDataLoadsAsEmpty() throws {
        let suiteName = "SyncQueueTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PendingCommandsStore(defaults: defaults)
        defaults.set(Data("not json".utf8), forKey: PendingCommandsStore.key)
        XCTAssertTrue(store.load().isEmpty)
    }

    // MARK: ClientGate

    @MainActor
    func testBackgroundGateBasics() async {
        let gate = ClientGate()
        XCTAssertTrue(gate.tryAcquireForBackground())
        XCTAssertFalse(gate.tryAcquireForBackground())  // already held
        gate.release()
        XCTAssertFalse(gate.isLocked)

        // An interactive holder blocks background acquisition.
        await gate.acquire()
        XCTAssertFalse(gate.tryAcquireForBackground())
        gate.release()
        XCTAssertTrue(gate.tryAcquireForBackground())
        gate.release()
    }

    @MainActor
    func testInteractiveOvertakesBackgroundWaiter() async throws {
        let gate = ClientGate()
        await gate.acquire()   // someone holds the client

        // Background drain parks in waitUntilIdle()…
        let bg = Task { @MainActor () -> Bool in
            await gate.waitUntilIdle()
            return gate.tryAcquireForBackground()
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        // …then an interactive job arrives while the holder still runs.
        let interactive = Task { @MainActor () -> Bool in
            await gate.acquire()
            return true
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(gate.interactiveWaitCount, 1)

        // Release hands the lock to the INTERACTIVE job, not the parked
        // background waiter.
        gate.release()
        let got = await interactive.value
        XCTAssertTrue(got)
        // The interactive job now holds the lock — background still out.
        XCTAssertFalse(gate.tryAcquireForBackground())

        // When it releases, the background waiter finally gets in.
        gate.release()
        let bgGot = await bg.value
        XCTAssertTrue(bgGot)
        gate.release()
    }

    @MainActor
    func testInteractiveIsFifo() async throws {
        let gate = ClientGate()
        await gate.acquire()
        var order: [Int] = []
        let a = Task { @MainActor in
            await gate.acquire(); order.append(1); gate.release()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let b = Task { @MainActor in
            await gate.acquire(); order.append(2); gate.release()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        gate.release()          // hand off to a
        await gate.acquire()    // waits behind b, then runs
        gate.release()
        await a.value
        await b.value
        XCTAssertEqual(order, [1, 2])
    }
}
