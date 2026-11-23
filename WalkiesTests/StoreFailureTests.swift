import Foundation
import Testing
@testable import Walkies

extension StoreTests {
    /// A directory at the destination makes the atomic replacement fail even when
    /// the test runner has permission to create temporary files beside it.
    @Test func aFailedCityFlushRetriesWithoutAnotherLocationFix() throws {
        let root = root()
        let store = Store(root: root)
        defer { store.wipe() }
        let original = city("Before", roads: street)
        let latest = city("After", roads: street)
        store.save([original])
        store.flush()
        let target = root.appending(path: "cities.json")
        let previous = root.appending(path: "cities.before.json")
        try FileManager.default.moveItem(at: target, to: previous)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        store.save([latest])
        store.flush()
        // The failure clears without a new GPS fix or another save request.
        try FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: previous, to: target)
        store.flush()
        #expect(Store(root: root).loadCities() == [latest])
    }

    @Test func aNewerSaveReplacesAFailedSnapshotAndWipeDiscardsRetries() throws {
        let root = root()
        let store = Store(root: root)
        defer { store.wipe() }
        let target = root.appending(path: "cities.json")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        store.save([city("Older", roads: street)])
        store.flush()
        let latest = city("Newest", roads: street)
        store.save([latest])
        store.flush()
        try FileManager.default.removeItem(at: target)
        store.flush()
        #expect(store.loadCities() == [latest])

        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        store.save([city("Must never return", roads: street)])
        store.flush()
        store.wipe()
        store.flush()
        #expect(Store(root: root).loadCities().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func aNewSnapshotQueuedDuringAFailedWriteWinsTheRetryRace() throws {
        let root = root()
        let store = Store(root: root)
        defer { store.wipe() }
        let target = root.appending(path: "cities.json")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let started = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        Store.cityWriteObserver.set { url in
            guard url == target else { return }
            started.signal()
            _ = finish.wait(timeout: .now() + 5)
        }
        defer { finish.signal(); Store.cityWriteObserver.set(nil) }
        store.save([city("In flight", roads: street)])
        #expect(started.wait(timeout: .now() + 5) == .success)
        let latest = city("Queued while writing", roads: street)
        store.save([latest])
        Store.cityWriteObserver.set(nil)
        finish.signal()
        // Both writes still fail. The older failure cannot replace the newer snapshot.
        store.flush()
        try FileManager.default.removeItem(at: target)
        store.flush()
        #expect(store.loadCities() == [latest])
    }

    @Test func aGridResetDiscardsAnySnapshotFromBeforeTheReset() throws {
        let root = root()
        let store = Store(root: root)
        defer { store.wipe() }
        let target = root.appending(path: "cities.json")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        store.save([city("Old grid", roads: street)])
        store.flush()
        try FileManager.default.removeItem(at: target)
        // prepareWorldGridReset flushes the retained snapshot before describing the
        // places to rebuild, then replaces their files. No old snapshot may reappear.
        try JSONEncoder().encode(HexGrid.version - 1).write(to: root.appending(path: "data-version.json"))
        try store.prepareWorldGridReset()
        store.flush()
        #expect(store.loadCities().isEmpty)
        #expect(try store.pendingResetPlaces().map(\.name) == ["Old grid"])
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func failedRoadReplacementKeepsStreetsInlineUntilTheNextSave() throws {
        let root = root()
        let store = Store(root: root)
        defer { store.wipe() }
        let roads = root.appending(path: "roads.json")
        try FileManager.default.createDirectory(at: roads, withIntermediateDirectories: false)
        let saved = city("Streets survive", roads: street)
        store.save([saved])
        store.flush()
        #expect(store.loadCities() == [saved])
        let inline = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "cities.json"))) as? [[String: Any]])
        #expect(inline.first?["roads"] != nil)
        try FileManager.default.removeItem(at: roads)
        store.save([saved])
        store.flush()
        #expect(Store(root: root).loadCities() == [saved])
        let separate = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "cities.json"))) as? [[String: Any]])
        #expect(separate.first?["roads"] == nil)
        #expect(try Data(contentsOf: roads).isEmpty == false)
    }

    @Test func interruptedWalkReplacementLeavesThePreviousCheckpointReadable() throws {
        let root = root()
        let store = Store(root: root)
        defer { store.wipe() }
        let saved = Walk(startedAt: Date(timeIntervalSince1970: 100), points: [
            TrackPoint(lat: -33.65, lon: 115.35, time: 100, accuracy: 5, speed: 1)
        ], automatic: true)
        store.save(saved)
        let target = root.appending(path: "walks/\(saved.id.uuidString).json")
        let before = try Data(contentsOf: target)
        // A killed writer can leave an incomplete temporary file, never a second
        // accepted checkpoint. The committed file remains the source of truth.
        try Data("{\"points\":".utf8).write(to: root.appending(path: "walks/.replacement.tmp"))
        let loaded = try #require(Store(root: root).loadWalks().only)
        #expect(loaded.id == saved.id)
        #expect(loaded.points == saved.points)
        #expect(try Data(contentsOf: target) == before)

        // Refuse the final replacement. A later valid save still replaces this UUID.
        let previous = root.appending(path: "walks/checkpoint.before")
        try FileManager.default.moveItem(at: target, to: previous)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        var newer = saved
        newer.points.append(TrackPoint(lat: -33.649, lon: 115.35, time: 200, accuracy: 5, speed: 1))
        store.save(newer)
        #expect(try Data(contentsOf: previous) == before)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: previous, to: target)
        store.save(newer)
        #expect(Store(root: root).loadWalks().only?.points == newer.points)
    }

    @Test func oneCorruptUnsyncedWalkDoesNotHideAnotherOrDeleteItsEvidence() throws {
        let root = root()
        let store = Store(root: root)
        defer { store.wipe() }
        let good = Walk(startedAt: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 200))
        store.save(good)
        let corrupt = root.appending(path: "walks/\(UUID().uuidString).json")
        let broken = Data("{\"points\":".utf8)
        try broken.write(to: corrupt)
        #expect(store.loadWalks().map(\.id) == [good.id])
        #expect(try Data(contentsOf: corrupt) == broken)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
